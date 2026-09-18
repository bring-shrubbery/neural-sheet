import SwiftUI

/// Every primitive in one place, so a change to the palette, the icon set or a control's states can
/// be eyeballed against the mockup without running the app.
struct Gallery: View {
    @State private var sliderValue: Double = 0.65
    @State private var steppedValue: Double = 4
    @State private var loopIsOn = true

    private let scale: CGFloat

    init(scale: CGFloat = 1) {
        self.scale = scale
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28 * scale) {
                section("Icons") { icons }
                section("FlatButton") { buttons }
                section("PillSlider") { sliders }
                section("MenuPanel") { menu }
                section("PopupSurface / tooltip") { surfaces }
            }
            .padding(24 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bgRoot)
        .uiScale(scale)
    }

    // MARK: - Sections

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            Text(title)
                .font(Fonts.sectionHeader(scale))
                .kerning(Fonts.tracking(Fonts.Tracking.sectionHeader,
                                        pointSize: Fonts.Size.sectionHeader,
                                        scale: scale))
                .foregroundStyle(Theme.textLabel)

            content()
        }
    }

    private var icons: some View {
        let side = 22 * scale

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 84 * scale), spacing: 12 * scale)],
                         alignment: .leading,
                         spacing: 12 * scale) {
            filled("skipToStart") { Icons.SkipToStart() }
            filled("play") { Icons.Play() }
            filled("pause") { Icons.Pause() }
            filled("record") { Icons.Record() }
            cell("loop") {
                ZStack {
                    Icons.LoopStroked().stroke(Theme.textIcon, style: Icons.strokeStyle(scale: scale))
                    Icons.LoopHead().fill(Theme.textIcon)
                }
                .frame(width: side, height: side)
            }
            cell("followPlayhead") {
                ZStack {
                    Icons.FollowPlayheadStroked().stroke(Theme.textIcon, style: Icons.strokeStyle(scale: scale))
                    Icons.FollowPlayheadFlag().fill(Theme.textIcon)
                }
                .frame(width: side, height: side)
            }
            filled("speaker") { Icons.Speaker() }
            filled("speakerMuted") { Icons.SpeakerMuted() }
            stroked("settings") { Icons.SettingsStroked() }
            stroked("folder") { Icons.FolderStroked() }
            stroked("download") { Icons.DownloadStroked() }
            stroked("trash") { Icons.TrashStroked() }
            cell("triangleUp") {
                Icons.TriangleUp().fill(Theme.textIcon).frame(width: 7 * scale, height: 4 * scale)
            }
            cell("triangleDown") {
                Icons.TriangleDown().fill(Theme.textIcon).frame(width: 7 * scale, height: 4 * scale)
            }
            stroked("plus") { Icons.PlusStroked() }
            stroked("cross") { Icons.CrossStroked() }
            cell("check") {
                Icons.CheckStroked()
                    .stroke(Theme.accent,
                            style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round))
                    .frame(width: side, height: side)
            }
            stroked("transcribe") { Icons.TranscribeStroked() }
            stroked("verticalZoom") { Icons.VerticalZoomStroked() }
            cell("checkbox") {
                HStack(spacing: 6 * scale) {
                    MenuCheckbox(isTicked: true)
                    MenuCheckbox(isTicked: false)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10 * scale) {
            labelled("idle") { transport(isOn: false, isEnabled: true) }
            labelled("on") { transport(isOn: true, isEnabled: true) }
            labelled("disabled") { transport(isOn: false, isEnabled: false) }
            labelled("hover / pressed") {
                FlatButton(idle: Theme.bgControl,
                           on: Theme.accentFillActive,
                           foregroundIdle: Theme.textButton,
                           foregroundOn: Theme.textBright,
                           corner: 6 * scale,
                           action: {}) { _ in
                    HStack(spacing: 7 * scale) {
                        Icons.TranscribeStroked()
                            .stroke(style: Icons.strokeStyle(scale: scale))
                            .frame(width: 14 * scale, height: 14 * scale)
                        Text("Transcribe")
                            .font(Fonts.buttonLabel(scale))
                    }
                    .padding(.horizontal, 14 * scale)
                    .frame(height: 30 * scale)
                }
            }
            labelled("loop toggle") {
                FlatButton(isOn: loopIsOn,
                           idle: .clear,
                           on: Theme.accentFillActive,
                           foregroundIdle: Theme.textIcon,
                           foregroundOn: Theme.accent,
                           corner: 6 * scale,
                           action: { loopIsOn.toggle() }) { _ in
                    ZStack {
                        Icons.LoopStroked().stroke(style: Icons.strokeStyle(scale: scale))
                        Icons.LoopHead().fill(.foreground)
                    }
                    .frame(width: 16 * scale, height: 16 * scale)
                    .frame(width: 34 * scale, height: 30 * scale)
                }
            }
        }
    }

    private func transport(isOn: Bool, isEnabled: Bool) -> some View {
        FlatButton(isOn: isOn,
                   isEnabled: isEnabled,
                   idle: .clear,
                   on: Theme.accentFillActive,
                   foregroundIdle: Theme.textIcon,
                   foregroundOn: Theme.accent,
                   corner: 6 * scale,
                   action: {}) { _ in
            Icons.Play()
                .fill(.foreground)
                .frame(width: 16 * scale, height: 16 * scale)
                .frame(width: 34 * scale, height: 30 * scale)
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            PillSlider(value: $sliderValue,
                       range: 0 ... 1,
                       width: 160 * scale,
                       fill: Theme.accent,
                       track: Theme.faderTrack,
                       thumb: Theme.faderThumb,
                       onDoubleClick: { sliderValue = 0.5 })

            PillSlider(value: $steppedValue,
                       range: 0 ... 10,
                       step: 1,
                       width: 160 * scale,
                       fill: Theme.volumeFill,
                       track: Theme.faderTrackTop,
                       thumb: nil)
        }
    }

    private var menu: some View {
        MenuPanel(title: "INSTRUMENT", footer: "Right-click a strip for more") {
            MenuRow(title: "Acoustic Grand Piano", isTicked: true) {}
            MenuRow(title: "Electric Bass (finger)") {}
            MenuSeparator()
            MenuRow(title: "Drum Kit", isEnabled: false) {}
            MenuRow(title: "Synth Lead") {}
        }
    }

    private var surfaces: some View {
        HStack(alignment: .top, spacing: 20 * scale) {
            Text("A popup surface")
                .font(Fonts.menuItem(scale))
                .foregroundStyle(Theme.popupItem)
                .padding(.horizontal, 11 * scale)
                .padding(.vertical, 6 * scale)
                .popupSurface(corner: 8 * scale)

            Text("Hover me for 800 ms")
                .font(Fonts.menuItem(scale))
                .foregroundStyle(Theme.textButton)
                .padding(.horizontal, 11 * scale)
                .padding(.vertical, 6 * scale)
                .background(RoundedRectangle(cornerRadius: 6 * scale).fill(Theme.bgControl))
                .tooltip("Tooltips wrap at 260 points and are placed away from whichever screen edge the pointer is nearest.")
        }
    }

    // MARK: - Cells

    private func cell(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 6 * scale) {
            content()
                .frame(height: 24 * scale)
            Text(name)
                .font(Fonts.meta(scale))
                .foregroundStyle(Theme.textFaintest)
        }
    }

    private func filled(_ name: String, shape: () -> some Shape) -> some View {
        cell(name) {
            shape().fill(Theme.textIcon).frame(width: 22 * scale, height: 22 * scale)
        }
    }

    private func stroked(_ name: String, shape: () -> some Shape) -> some View {
        cell(name) {
            shape()
                .stroke(Theme.textIcon, style: Icons.strokeStyle(scale: scale))
                .frame(width: 22 * scale, height: 22 * scale)
        }
    }

    private func labelled(_ name: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 6 * scale) {
            content()
            Text(name)
                .font(Fonts.meta(scale))
                .foregroundStyle(Theme.textFaintest)
        }
    }
}

#Preview("Controls gallery") {
    Gallery()
        .frame(width: 900, height: 760)
}

#Preview("Controls gallery @ 1.5x") {
    Gallery(scale: 1.5)
        .frame(width: 1100, height: 800)
}
