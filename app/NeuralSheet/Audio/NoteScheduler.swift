import Foundation
import NeuralSheetCore
import Synchronization

/// One note-on or note-off, at a sample offset inside the block that produced it.
///
/// It carries the instrument rather than a MIDI channel: a transcription names 35 instruments and
/// MIDI has 16 channels, and deciding *when* a note happens has nothing to do with that mapping.
/// ``InstrumentSynthBank`` is what turns a program into a synth and a channel.
nonisolated struct SynthEvent: Equatable, Sendable {
    var sampleOffset: Int
    var program: Int
    var pitch: Int
    var isOn: Bool
}

/// The note list as the render thread sees it: a flat, immutable buffer it can index without
/// touching a refcount.
///
/// A Swift array behind a class property would be read through a retain of its storage; one
/// allocation here, at swap time, buys pure pointer arithmetic in the block.
private nonisolated final class NoteList: @unchecked Sendable {
    let notes: UnsafeMutableBufferPointer<NoteEvent>

    var count: Int { notes.count }

    init(_ source: [NoteEvent]) {
        notes = UnsafeMutableBufferPointer<NoteEvent>.allocate(capacity: source.count)
        _ = notes.initialize(fromContentsOf: source)
    }

    deinit {
        notes.deinitialize()
        notes.deallocate()
    }
}

/// Turns a note list into note-ons and note-offs, block by block. Port of the C++ `NoteScheduler`
/// (`Lib/Player/NoteScheduler.cpp`), inventory §5.1.
///
/// Its invariant: **every note-on it emits is followed by a matching note-off**. Note-offs are
/// generated from a table of what this class started, never looked up in the note list, so nothing
/// that happens to that list can strand a sounding note — which matters because the list is replaced
/// once per decoded chunk while a transcription streams in.
///
/// Threading. ``collect(from:to:sampleRate:into:)`` is the render thread's and nothing else's: it
/// owns the active-note table, the cursor and the render thread's view of the list, and it neither
/// allocates nor locks. ``swap(notes:)``, ``seek(toSeconds:)`` and ``requestAllNotesOff()`` are the
/// main thread's and reach it only through atomics and a single-word pointer swap — a replaced list
/// is held for a grace period, exactly as ``PlaybackEngine`` holds a replaced take, so the block can
/// never index freed memory.
///
/// Time comes from the caller rather than being accumulated here: ``PlaybackEngine``'s render block
/// already owns the playhead, and a second copy of it would be one more thing to keep in step. A
/// block with `t1 == t0` is the transport standing still — nothing new starts, but anything sounding
/// is still released, because a stop mid-note owes the synth a note-off.
nonisolated final class NoteScheduler: @unchecked Sendable {
    /// Also the polyphony ceiling. Reaching it steals the oldest note rather than dropping a
    /// note-off. Sized for headroom: 35 instruments each have 128 pitches, so the old "128 pitches
    /// on one channel cannot exceed 256" argument no longer bounds it.
    static let maxActiveNotes = 512

    /// How far back a re-anchor or a re-attack looks for the note a sounding pitch came from. A
    /// covering note starts before the playhead, and proving one absent would otherwise mean
    /// scanning the whole history inside the render block. Not finding a match only stops a note
    /// early, never leaves one sounding, so the bound errs in the harmless direction.
    static let maxLookbackSeconds = 30.0

    /// Enough for every active note to be released and a fresh set started without reallocating.
    /// This is the ceiling the *onset* pass stops adding at, not the most one block can produce.
    static let eventCapacity = 4 * maxActiveNotes

    /// What `events` has to be reserved to, and what ``InstrumentSynthBank`` reserves.
    ///
    /// Larger than ``eventCapacity`` because the expiry pass that runs *after* the onset pass is not
    /// optional — giving up a note-off would strand a sounding note — and it can stop every note the
    /// onset pass left sounding. Reserving both is what makes "never reallocates on the render
    /// thread" a guarantee rather than a hope.
    static let reservedEventCapacity = eventCapacity + maxActiveNotes

    /// A note this class has started and not yet stopped.
    private struct ActiveNote {
        var program = 0
        var pitch = 0
        var endTime = 0.0
    }

    // MARK: - Shared between the threads

    /// What the render thread reads, as a single machine word written only from the main thread. The
    /// generation below is what orders the two.
    private let box = UnsafeMutablePointer<Unmanaged<NoteList>?>.allocate(capacity: 1)

    /// Bumped by ``swap(notes:)`` after ``box`` is written, so a render thread that sees the new
    /// generation also sees the new list.
    private let listGeneration = Atomic<Int>(0)

    /// Raised when the playhead moves or the transport stops. The next block releases everything
    /// sounding; the next *playing* block then re-attacks whatever covers the new position, and only
    /// then is it cleared — so a pause holds the flag until playback actually resumes.
    private let shouldResync = Atomic<Bool>(false)

    // MARK: - The main thread's

    /// Strong reference to what ``box`` points at.
    private var currentList: NoteList?

    /// Lists the box no longer points at, held until the render block cannot be inside them.
    private var retiredLists: [NoteList] = []

    /// How long a replaced list is kept alive after the box stops pointing at it. Orders of
    /// magnitude more than one render cycle, which is all the block needs.
    private static let retirementSeconds = 0.5

    /// Whether the current list has anything in it. Written by ``swap(notes:)``, read by
    /// ``PlaybackEngine`` to force the mix to all-source when there is nothing to play (§5.3).
    private(set) var hasNotes = false

    // MARK: - The render thread's

    /// The published list as the render thread sees it: the buffer, not a reference to the object
    /// that owns it.
    ///
    /// An owning reference stored here would make the render thread capable of performing a final
    /// release — and so a `free` — if a swap landed while the engine was stopped for longer than the
    /// retirement window. The main thread owns every ``NoteList``'s lifetime; this is a borrow, held
    /// valid by ``currentList`` and ``retiredLists``.
    private var publishedNotes = UnsafeMutableBufferPointer<NoteEvent>(start: nil, count: 0)
    private var listGenerationSeen = 0

    /// Index of the first note starting at or after the current time.
    private var cursor = 0

    /// Kept in the order notes started, so index 0 is the oldest.
    private let active: UnsafeMutableBufferPointer<ActiveNote>
    private var activeCount = 0

    /// Where the previous block ended. A block that does not start there is a discontinuity — a
    /// wrap, or a seek whose flag has not arrived yet — and the cursor is rebuilt.
    private var lastEndTime = -1.0

    init() {
        box.initialize(to: nil)

        active = UnsafeMutableBufferPointer<ActiveNote>.allocate(
            capacity: NoteScheduler.maxActiveNotes)
        active.initialize(repeating: ActiveNote())
    }

    deinit {
        box.deinitialize(count: 1)
        box.deallocate()

        active.deinitialize()
        active.deallocate()
    }

    // MARK: - Main thread

    /// Swaps in a new note list, which is expected sorted by start time and is sorted here if it is
    /// not — the cursor is a binary search, and an unsorted list would silently mis-place it.
    ///
    /// Notes already sounding survive if the new list still has them: a transcription streams in a
    /// chunk at a time and cutting every held note ~48 times over a song would be audible. The
    /// re-anchoring itself happens in the next ``collect(from:to:sampleRate:into:)``, the only place
    /// the active table is touched. A note the new list no longer has gets an end time in the past
    /// there, so it stops through the same path as any note reaching its end — it cannot simply be
    /// forgotten.
    func swap(notes: [NoteEvent]) {
        let sorted = NoteScheduler.isSortedByStart(notes) ? notes : notes.sorted()
        let next = NoteList(sorted)
        let retiring = currentList

        currentList = next
        hasNotes = !sorted.isEmpty

        box.pointee = Unmanaged.passUnretained(next)
        // Released after the pointer write, acquired on the other side before the pointer read.
        listGeneration.wrappingAdd(1, ordering: .releasing)

        retire(retiring)
    }

    /// Moves the playhead. Everything sounding is released in the next block — it does not belong
    /// where the playhead now is — and the notes covering the new position are re-attacked once the
    /// transport is running again, so landing inside a held chord is not silent until the next onset.
    ///
    /// The position itself arrives through the render block, which owns the playhead; this only has
    /// to say that it moved.
    func seek(toSeconds seconds: Double) {
        _ = seconds
        shouldResync.store(true, ordering: .relaxed)
    }

    /// Asks for a clean set of note-offs on the next block.
    func requestAllNotesOff() {
        shouldResync.store(true, ordering: .relaxed)
    }

    /// Holds a replaced list until any render block that saw it has long since returned.
    private func retire(_ list: NoteList?) {
        guard let list else { return }

        retiredLists.append(list)

        DispatchQueue.main.asyncAfter(deadline: .now() + NoteScheduler.retirementSeconds) {
            [weak self] in
            guard let self else { return }
            if let index = self.retiredLists.firstIndex(where: { $0 === list }) {
                self.retiredLists.remove(at: index)
            }
        }
    }

    private static func isSortedByStart(_ notes: [NoteEvent]) -> Bool {
        guard notes.count > 1 else { return true }

        for index in 1..<notes.count where notes[index - 1].startTime > notes[index].startTime {
            return false
        }

        return true
    }

    // MARK: - Render thread

    /// Fills `events` with everything that happens in `[t0, t1)`, in nondecreasing sample offset and
    /// with a note-off always ahead of a note-on it shares an offset with.
    ///
    /// Allocation- and lock-free: `events` is pre-reserved by the caller to
    /// ``reservedEventCapacity`` and can never exceed it, the active table is a fixed buffer, and
    /// the note list arrives as one pointer read.
    func collect(
        from t0: Double, to t1: Double, sampleRate: Double, into events: inout [SynthEvent]
    ) {
        events.removeAll(keepingCapacity: true)

        guard sampleRate > 0, t0.isFinite, t1.isFinite else { return }

        let playing = t1 > t0
        let frames = Swift.max(0, Int(((t1 - t0) * sampleRate).rounded()))

        // A new list re-anchors what is sounding rather than cutting it.
        let generation = listGeneration.load(ordering: .acquiring)
        if generation != listGenerationSeen {
            listGenerationSeen = generation
            // Unretained, and only the buffer is kept: the object's lifetime stays the main
            // thread's. The transient +0 reference here cannot be the last one, because `swap`
            // holds the list it replaced for the retirement window.
            if let published = box.pointee {
                publishedNotes = published.takeUnretainedValue().notes
            } else {
                publishedNotes = UnsafeMutableBufferPointer<NoteEvent>(start: nil, count: 0)
            }

            updateCursor(at: t0)
            reanchorActive(at: t0)
        } else if t0 != lastEndTime {
            updateCursor(at: t0)
        }

        if shouldResync.load(ordering: .relaxed) {
            while activeCount > 0 {
                stopActive(at: activeCount - 1, sampleOffset: 0, into: &events)
            }

            if playing {
                // Only once playing: a stopped transport keeps the flag so that resuming re-attacks
                // what the playhead is sitting inside, instead of staying silent until the next
                // onset.
                updateCursor(at: t0)
                startNotesCovering(t0, into: &events)
                shouldResync.store(false, ordering: .relaxed)
            }
        }

        guard playing else {
            // Time does not advance and nothing new starts, but the release above still had to run:
            // a transport stopping mid-note owes the synth a note-off.
            sort(&events)
            lastEndTime = t1
            return
        }

        expire(before: t1, t0: t0, sampleRate: sampleRate, frames: frames, into: &events)

        while cursor < publishedNotes.count, publishedNotes[cursor].startTime < t1 {
            let note = publishedNotes[cursor]
            cursor += 1

            // Already over by the time we reached it — post-processing can shorten a note under a
            // running playhead. Starting it would only produce a note-on chasing its own note-off.
            if note.endTime <= t0 { continue }

            // Three events is the most one onset can add: a retrigger release, a steal release and
            // the note-on itself. The onset pass is the only one allowed to give up — the expiry
            // pass below it has to run whatever happens — so this is where the growth stops, and
            // only note-ons are ever given up, which leaves the note-off invariant intact. The
            // expiry pass then adds at most ``maxActiveNotes`` more, which is why the caller
            // reserves ``reservedEventCapacity`` rather than ``eventCapacity``.
            if events.count + 3 > NoteScheduler.eventCapacity { break }

            let offset = sampleOffset(
                for: note.startTime, t0: t0, sampleRate: sampleRate, frames: frames)

            // Only the same instrument's note on this pitch: two instruments playing the same note
            // is ordinary, and releasing the other one would silence it for the rest of its
            // duration.
            let sounding = findActive(program: note.program, pitch: note.pitch)

            if sounding < activeCount {
                // A retrigger has to release the previous one first, or the note-off that eventually
                // arrives reads as ending this one instead.
                stopActive(at: sounding, sampleOffset: offset, into: &events)
            }

            if activeCount == NoteScheduler.maxActiveNotes {
                stopActive(at: 0, sampleOffset: offset, into: &events)
            }

            active[activeCount] = ActiveNote(
                program: note.program, pitch: note.pitch, endTime: note.endTime)
            activeCount += 1

            events.append(
                SynthEvent(
                    sampleOffset: offset, program: note.program, pitch: note.pitch, isOn: true))
        }

        // Again, for notes that both start and end inside this block. A drum hit lasts 10 ms, which
        // is shorter than a block at most sizes, so without this pass they would all be stretched to
        // one. Unguarded, deliberately: the reservation above covers it.
        expire(before: t1, t0: t0, sampleRate: sampleRate, frames: frames, into: &events)

        sort(&events)
        lastEndTime = t1
    }

    /// Re-points every sounding note at the note that covers it in the current list, or at an end
    /// time in the past when the list no longer has one.
    private func reanchorActive(at time: Double) {
        for index in 0..<activeCount {
            active[index].endTime = endTimeOfCoveringNote(
                program: active[index].program, pitch: active[index].pitch, at: time)
        }
    }

    /// Starts the notes the playhead is currently inside, after a seek or a resume.
    private func startNotesCovering(_ time: Double, into events: inout [SynthEvent]) {
        let earliest = time - NoteScheduler.maxLookbackSeconds

        // Backwards from the cursor, so the first match on an instrument and pitch is the latest
        // note to have started there — the one actually sounding at this point.
        var index = cursor
        while index > 0 {
            index -= 1
            let note = publishedNotes[index]

            if note.startTime < earliest { break }
            if note.startTime > time || note.endTime <= time { continue }

            let alreadySounding = findActive(program: note.program, pitch: note.pitch) < activeCount

            if alreadySounding || activeCount == NoteScheduler.maxActiveNotes { continue }
            if events.count >= NoteScheduler.eventCapacity { break }

            active[activeCount] = ActiveNote(
                program: note.program, pitch: note.pitch, endTime: note.endTime)
            activeCount += 1

            events.append(
                SynthEvent(sampleOffset: 0, program: note.program, pitch: note.pitch, isOn: true))
        }
    }

    /// The end time of the note in the current list that covers `time` on this instrument and pitch,
    /// or a negative value if there is none — which stops the sounding note in the next block.
    private func endTimeOfCoveringNote(program: Int, pitch: Int, at time: Double) -> Double {
        let earliest = time - NoteScheduler.maxLookbackSeconds

        // The cursor is the first note starting at or after `time`, so anything that could cover it
        // is behind that.
        var index = cursor
        while index > 0 {
            index -= 1
            let note = publishedNotes[index]

            if note.startTime < earliest { break }

            if note.program == program, note.pitch == pitch, note.startTime <= time,
                note.endTime > time
            {
                return note.endTime
            }
        }

        return -1
    }

    /// Stops everything that has ended before `limit`.
    private func expire(
        before limit: Double, t0: Double, sampleRate: Double, frames: Int,
        into events: inout [SynthEvent]
    ) {
        var index = 0

        while index < activeCount {
            if active[index].endTime < limit {
                let offset = sampleOffset(
                    for: active[index].endTime, t0: t0, sampleRate: sampleRate, frames: frames)
                stopActive(at: index, sampleOffset: offset, into: &events)
            } else {
                index += 1
            }
        }
    }

    /// Drops the entry at `index`, emitting its note-off first. Keeps the rest in start order.
    private func stopActive(at index: Int, sampleOffset: Int, into events: inout [SynthEvent]) {
        let note = active[index]

        events.append(
            SynthEvent(
                sampleOffset: sampleOffset, program: note.program, pitch: note.pitch, isOn: false))

        for i in (index + 1)..<activeCount {
            active[i - 1] = active[i]
        }

        activeCount -= 1
    }

    /// The index of the sounding note on this instrument and pitch, or ``activeCount`` if there is
    /// none.
    private func findActive(program: Int, pitch: Int) -> Int {
        for index in 0..<activeCount
        where active[index].program == program && active[index].pitch == pitch {
            return index
        }

        return activeCount
    }

    /// Points ``cursor`` at the first note starting at or after `time`. An empty list leaves it at
    /// 0, which is what every backwards walk below reads as "nothing to look at".
    private func updateCursor(at time: Double) {
        var low = 0
        var high = publishedNotes.count

        while low < high {
            let mid = low + (high - low) / 2
            if publishedNotes[mid].startTime < time { low = mid + 1 } else { high = mid }
        }

        cursor = low
    }

    /// Puts the block's events back into sample order. They are appended in the order the block's
    /// passes happen — expiry walks the active table in start order, not end order — so the offsets
    /// come out shuffled. Insertion sort because it is stable, which is what keeps a note-off ahead
    /// of the note-on that shares its offset, and because the list is short and nearly sorted.
    private func sort(_ events: inout [SynthEvent]) {
        guard events.count > 1 else { return }

        for i in 1..<events.count {
            let event = events[i]
            var j = i

            // Strictly greater, so equal offsets keep the order they were emitted in.
            while j > 0, events[j - 1].sampleOffset > event.sampleOffset {
                events[j] = events[j - 1]
                j -= 1
            }

            events[j] = event
        }
    }

    private func sampleOffset(for time: Double, t0: Double, sampleRate: Double, frames: Int) -> Int {
        // The engine can hand us an empty block; there is no offset to place anything at.
        guard frames > 0 else { return 0 }

        let offset = ((time - t0) * sampleRate).rounded()
        guard offset.isFinite else { return 0 }

        return Int(Swift.min(Swift.max(offset, 0), Double(frames - 1)))
    }
}
