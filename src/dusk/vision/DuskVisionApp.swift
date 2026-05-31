// Dusk visionOS scene-activation seam (SwiftUI @main).
//
// This file is compiled ONLY for visionOS (see the `if (VISIONOS)` block in CMakeLists.txt that adds
// it to the dusklight target and enables the Swift language). It is the process entry point on
// visionOS: a SwiftUI App that
//   1. spawns the existing C++/engine main loop (aurora_main -> DuskMain) on a background thread, and
//   2. opens an ImmersiveSpace hosting a CompositorServices CompositorLayer, captures the vended
//      LayerRenderer (-> cp_layer_renderer_t) and hands it to the C++ present loop
//      (dusk::vision::runStereoPresentLoop, reached via the C shim dusk_vision_start_present).
//
// The C shims live in StereoEntry.h (the Swift bridging header) and are implemented in
// StereoPresent.mm. We use plain-C functions + an opaque void* for the layer renderer rather than
// C++ interop, which is the most robust Swift<->C bridge here.
//
// SCAFFOLD: compile-and-link verified. Runtime (SDL lifecycle coexistence, actual stereo present) is
// NOT verified -- there is no device/sim run. See StereoPresent.mm and the report for caveats.

import SwiftUI
import CompositorServices
import Foundation

// Identifier for the transient launch window so we can dismiss it once the immersive space opens.
private let kLaunchWindowID = "DuskLaunch"

// MARK: - Engine bootstrap

// Kick the engine main loop off exactly once, on a dedicated background thread, since aurora_main
// blocks for the lifetime of the game.
private let engineStart: Void = {
    Thread.detachNewThread {
        Thread.current.name = "DuskEngine"
        // Forward the real process arguments (so --dvd <path> etc. still work) as a C argv array.
        let args = CommandLine.arguments
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        cargs.append(nil)  // argv is NULL-terminated.
        let cargsCount = cargs.count  // Captured before the exclusive-access closure below.
        cargs.withUnsafeMutableBufferPointer { buf in
            // The C shim takes `const char* const*` (Swift: UnsafePointer<UnsafePointer<CChar>?>);
            // rebind the mutable buffer base to the const-pointer element type. aurora/SDL do not
            // mutate argv contents, so this is safe.
            buf.baseAddress!.withMemoryRebound(
                to: UnsafePointer<CChar>?.self, capacity: cargsCount) { cargv in
                _ = dusk_vision_run_engine(Int32(args.count), cargv)
            }
        }
        for p in cargs where p != nil { free(p) }
    }
}()

private func startEngineOnce() { _ = engineStart }

// MARK: - Compositor content

// The CompositorLayer's render closure receives a LayerRenderer (Swift wrapper) which bridges to the
// C `cp_layer_renderer_t`. We pass it to C as an opaque pointer; the .mm side casts it back. The
// present loop blocks, so it runs on its own thread.
// CompositorContent / CompositorLayer's CompositorContent-based initializer is visionOS 26.0+.
@available(visionOS 26.0, *)
struct DuskCompositorContent: CompositorContent {
    var body: some CompositorContent {
        CompositorLayer { layerRenderer in
            Thread.detachNewThread {
                Thread.current.name = "DuskStereoPresent"
                // `layerRenderer` is an Objective-C object (cp_layer_renderer_t) under the hood;
                // pass it to C as a retained opaque pointer. dusk_vision_start_present blocks for the
                // lifetime of the immersive scene.
                let handle = Unmanaged.passUnretained(layerRenderer).toOpaque()
                dusk_vision_start_present(handle)
            }
        }
    }
}

// MARK: - App

@main
struct DuskVisionApp: App {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        // visionOS apps need an initial windowed scene; this tiny window requests the immersive
        // space on appear and then dismisses itself so the game (presented into the immersive
        // CompositorLayer) isn't occluded by the launch placeholder.
        WindowGroup(id: kLaunchWindowID) {
            LaunchView()
                .task {
                    // Boot the engine only AFTER the app/scene is up. The engine runs on a background
                    // thread but marshals its SDL/UIKit-bound init (SDL_INIT_VIDEO, window creation,
                    // event pump) onto the main thread via GCD; that requires the UIApplication/scene
                    // and a live main run loop to exist first. Starting it in App.init() was too early
                    // (the UIApplication/scene was not ready and SDL video init aborted). .task runs on
                    // the main actor once the scene appears -- the correct, late-enough kickoff point.
                    startEngineOnce()
                    let result = await openImmersiveSpace(id: "DuskStereo")
                    switch result {
                    case .opened:
                        NSLog("[dusk::vision] openImmersiveSpace(DuskStereo): opened")
                        // NOTE: keep the launch window for now. Dismissing it can drop the app's
                        // last foreground scene before the immersive content is actually presenting,
                        // which (on device) lets the app background and stops world tracking. Re-add
                        // dismissal once the immersive stereo present is confirmed rendering.
                    case .userCancelled:
                        NSLog("[dusk::vision] openImmersiveSpace(DuskStereo): userCancelled")
                    case .error:
                        NSLog("[dusk::vision] openImmersiveSpace(DuskStereo): ERROR")
                    @unknown default:
                        NSLog("[dusk::vision] openImmersiveSpace(DuskStereo): unknown result")
                    }
                }
        }
        .windowResizability(.contentSize)

        // The CompositorContent-hosting ImmersiveSpace initializer is visionOS 26.0+. The app's
        // deployment target is lower, so gate the scene; on older systems the immersive open simply
        // fails (the windowed LaunchView still appears).
        if #available(visionOS 26.0, *) {
            ImmersiveSpace(id: "DuskStereo") {
                DuskCompositorContent()
            }
            // REQUIRED for a CompositorLayer to actually composite into the view. Without an explicit
            // immersion style the space defaults to .mixed, and our rendered drawables were never shown
            // (even a forced opaque-red clear stayed invisible -- only the windowed LaunchView panel
            // appeared). Apple's "fully immersive Metal" sample sets .full here. Hide the rendered
            // hands/limbs since the game owns the whole view.
            .immersionStyle(selection: .constant(.full), in: .full)
            .upperLimbVisibility(.hidden)
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Dusklight")
                .font(.largeTitle)
            ProgressView()
            Text("Launching…")
                .foregroundStyle(.secondary)
        }
        .padding(40)
    }
}
