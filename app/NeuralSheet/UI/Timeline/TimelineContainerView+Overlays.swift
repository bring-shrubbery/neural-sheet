import AppKit
import NeuralSheetCore
import SwiftUI

/// The container's overlays: the Transcribe call-to-action over the roll and the load button over
/// the waveform, out of `TimelineContainerView.swift` to keep that file focused.
extension TimelineContainerView {
    func installOverlays() {
        let cta = OverlayHost(rootView: TranscribeCTA(label: model.transcribeLabel, isEnabled: false, scale: scale,
                                                      action: { [weak self] in self?.model.launchTranscription() }))
        cta.isHidden = true
        addSubview(cta)
        ctaHost = cta

        let load = OverlayHost(rootView: LoadAudioButton(scale: scale, action: { [weak self] in
            guard let self, let url = LoadAudioButton.chooseFile() else { return }

            self.model.loadAudio(url: url)
        }))
        load.isHidden = true
        addSubview(load)
        loadHost = load
    }

    /// `VisualizationPanel::_layOutTranscribeButton` and `AudioRegion::resized`: the Transcribe
    /// call-to-action centred on the roll's viewport, the load button centred on the waveform's.
    func placeOverlays() {
        let k = scale
        let state = model.state
        let rollIsIdle = state == .audioLoaded || state == .empty
        let hasModel = model.hasTranscriptionModel

        if let ctaHost {
            ctaHost.rootView = TranscribeCTA(label: model.transcribeLabel, isEnabled: state == .audioLoaded, scale: k,
                                             action: { [weak self] in self?.model.launchTranscription() })
            ctaHost.isHidden = !(rollIsIdle && hasModel) || mode == .edit

            let viewport = scrollView.frame
            let rollRegion = CGRect(x: viewport.minX, y: viewport.minY + geometry.rollY * k,
                                    width: viewport.width, height: max(0, viewport.height - geometry.rollY * k))

            ctaHost.place(centredIn: rollRegion)
        }

        if let loadHost {
            loadHost.rootView = LoadAudioButton(scale: k, action: { [weak self] in
                guard let self, let url = LoadAudioButton.chooseFile() else { return }

                self.model.loadAudio(url: url)
            })
            loadHost.isHidden = state != .empty || mode == .edit

            let viewport = scrollView.frame
            let waveformRegion = CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width,
                                        height: geometry.waveformHeight * k)

            loadHost.place(centredIn: waveformRegion, top: waveformRegion.minY + WaveformView.loadButtonY(scale: k))
        }
    }
}
