import Foundation

public enum ProjectTemplate: String, CaseIterable {
    case twoD = "2d"
    case threeD = "3d"
    case shader
    case live
    case audioReactive = "audio-reactive"
    case raytracing
    case syphon

    public var title: String {
        switch self {
        case .twoD: "2D sketch"
        case .threeD: "3D sketch"
        case .shader: "Custom post-process shader"
        case .live: "Live performance controls"
        case .audioReactive: "Audio reactive sketch"
        case .raytracing: "Metal ray tracing sketch"
        case .syphon: "Syphon output sketch"
        }
    }

    public var summary: String {
        switch self {
        case .twoD:
            "Minimal Processing-style 2D sketch."
        case .threeD:
            "Camera, lights, and animated 3D primitives."
        case .shader:
            "Sketch with a custom Metal post-process effect."
        case .live:
            "Parameter GUI, OSC input, MIDI input, and performance HUD."
        case .audioReactive:
            "Microphone FFT analysis driving visuals."
        case .raytracing:
            "MPS/Metal ray tracing starter scene."
        case .syphon:
            "Fixed-resolution output configured for Syphon."
        }
    }
}

public struct TemplateContext {
    public let projectName: String
    public let moduleName: String
    public let template: ProjectTemplate
    public let metaphorDependency: String
    public let metaphorPackageIdentity: String

    public init(
        projectName: String,
        moduleName: String,
        template: ProjectTemplate,
        metaphorDependency: String,
        metaphorPackageIdentity: String
    ) {
        self.projectName = projectName
        self.moduleName = moduleName
        self.template = template
        self.metaphorDependency = metaphorDependency
        self.metaphorPackageIdentity = metaphorPackageIdentity
    }
}

public struct GeneratedFile: Equatable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public enum TemplateRenderer {
    public static func files(for context: TemplateContext) -> [GeneratedFile] {
        [
            GeneratedFile(path: "Package.swift", contents: packageSwift(context)),
            GeneratedFile(path: ".gitignore", contents: gitignore()),
            GeneratedFile(path: "README.md", contents: readme(context)),
            GeneratedFile(path: "Sources/\(context.moduleName)/App.swift", contents: appSwift(context)),
            GeneratedFile(path: "Sources/\(context.moduleName)/Resources/Images/.gitkeep", contents: "\n"),
            GeneratedFile(path: "Sources/\(context.moduleName)/Resources/Models/.gitkeep", contents: "\n"),
            GeneratedFile(path: "Sources/\(context.moduleName)/Resources/Shaders/.gitkeep", contents: "\n"),
            GeneratedFile(path: "Sources/\(context.moduleName)/Presets/default.json", contents: defaultPreset(context)),
        ]
    }

    public static func packageSwift(_ context: TemplateContext) -> String {
        """
        // swift-tools-version: 5.10

        import PackageDescription

        let package = Package(
            name: "\(context.projectName.swiftLiteralEscaped)",
            platforms: [
                .macOS(.v14)
            ],
            dependencies: [
                \(context.metaphorDependency)
            ],
            targets: [
                .executableTarget(
                    name: "\(context.moduleName)",
                    dependencies: [
                        .product(name: "metaphor", package: "\(context.metaphorPackageIdentity)")
                    ],
                    resources: [
                        .process("Resources"),
                        .process("Presets"),
                    ]
                ),
            ]
        )
        """
    }

    public static func appSwift(_ context: TemplateContext) -> String {
        switch context.template {
        case .twoD:
            app2D(context)
        case .threeD:
            app3D(context)
        case .shader:
            appShader(context)
        case .live:
            appLive(context)
        case .audioReactive:
            appAudioReactive(context)
        case .raytracing:
            appRayTracing(context)
        case .syphon:
            appSyphon(context)
        }
    }

    private static func app2D(_ context: TemplateContext) -> String {
        """
        import metaphor

        @main
        final class \(context.moduleName): Sketch {
            var config: SketchConfig {
                SketchConfig(width: 1280, height: 720, title: "\(context.projectName.swiftLiteralEscaped)")
            }

            func setup() {
                frameRate(60)
            }

            func draw() {
                background(0.04, 0.05, 0.07)
                noStroke()

                let pulse = 0.5 + 0.5 * sin(time * 2.0)
                let radius = 80 + pulse * 48

                fill(0.9, 0.25 + pulse * 0.3, 0.15)
                circle(mouseX, mouseY, radius)

                fill(1)
                textSize(16)
                text("\(context.projectName.swiftLiteralEscaped)", 24, 28)
            }
        }
        """
    }

    private static func app3D(_ context: TemplateContext) -> String {
        """
        import metaphor

        @main
        final class \(context.moduleName): Sketch {
            var config: SketchConfig {
                SketchConfig(width: 1280, height: 720, title: "\(context.projectName.swiftLiteralEscaped)")
            }

            func setup() {
                frameRate(60)
                enablePerformanceHUD()
            }

            func draw() {
                background(0.02, 0.025, 0.035)
                lights()
                noStroke()

                push()
                translate(width * 0.5, height * 0.5, -120)
                rotateX(-0.45)
                rotateY(time * 0.8)
                metallic(0.2)
                roughness(0.35)
                fill(0.95, 0.35, 0.18)
                box(180)
                pop()

                push()
                translate(width * 0.72, height * 0.48, -260)
                rotateY(-time * 0.55)
                fill(0.25, 0.62, 1.0)
                torus(ringRadius: 100, tubeRadius: 26, detail: 36)
                pop()
            }
        }
        """
    }

    private static func appShader(_ context: TemplateContext) -> String {
        ##"""
        import metaphor

        @main
        final class \##(context.moduleName): Sketch {
            private var chromaShift: CustomPostEffect?

            var config: SketchConfig {
                SketchConfig(width: 1280, height: 720, title: "\##(context.projectName.swiftLiteralEscaped)")
            }

            func setup() {
                let source = PostProcessShaders.commonStructs + #"""
                fragment float4 metaphorTemplateChromaShift(
                    PPVertexOut in [[stage_in]],
                    texture2d<float> tex [[texture(0)]],
                    constant PostProcessParams &params [[buffer(0)]]
                ) {
                    constexpr sampler s(address::clamp_to_edge, filter::linear);
                    float2 uv = in.texCoord;
                    float amount = 0.008 + params.intensity * 0.02;
                    float r = tex.sample(s, uv + float2(amount, 0.0)).r;
                    float g = tex.sample(s, uv).g;
                    float b = tex.sample(s, uv - float2(amount, 0.0)).b;
                    return float4(r, g, b, 1.0);
                }
                """#

                do {
                    let effect = try createPostEffect(
                        name: "Chroma Shift",
                        source: source,
                        fragmentFunction: "metaphorTemplateChromaShift"
                    )
                    effect.intensity = 0.35
                    chromaShift = effect
                    addPostEffect(effect)
                } catch {
                    print("Failed to create post effect: \(error)")
                }
            }

            func draw() {
                background(0.03, 0.035, 0.05)
                noStroke()

                for i in 0..<18 {
                    let t = Float(i) / 18.0
                    let angle = time * (0.6 + t) + t * Float.pi * 2
                    let x = width * 0.5 + cos(angle) * (130 + t * 240)
                    let y = height * 0.5 + sin(angle * 1.7) * (70 + t * 120)
                    fill(0.2 + t * 0.8, 0.8 - t * 0.45, 1.0, 0.78)
                    circle(x, y, 42 + t * 58)
                }
            }
        }
        """##
    }

    private static func appLive(_ context: TemplateContext) -> String {
        """
        import metaphor

        @main
        final class \(context.moduleName): Sketch {
            private var osc: OSCReceiver?
            private var midi: MIDIManager?

            private var radius: Float = 90
            private var speed: Float = 1.0
            private var hue: Float = 0.58
            private var showTrails = true

            var config: SketchConfig {
                SketchConfig(width: 1280, height: 720, title: "\(context.projectName.swiftLiteralEscaped)")
            }

            func setup() {
                enablePerformanceHUD()

                osc = createOSCReceiver(port: 9000)
                do {
                    try osc?.start()
                } catch {
                    print("OSC unavailable: \\(error)")
                }

                midi = createMIDI()
                midi?.start()
            }

            func draw() {
                readControls()

                if showTrails {
                    background(0, 0, 0, 0.08)
                } else {
                    background(0.02)
                }

                noStroke()
                colorMode(.hsb, 1)
                fill(hue, 0.82, 0.95, 0.9)

                let orbit = 180 + radius
                let x = width * 0.5 + cos(time * speed) * orbit
                let y = height * 0.5 + sin(time * speed * 1.37) * orbit * 0.55
                circle(x, y, radius)

                colorMode(.rgb, 1)
                drawGUI()
            }

            private func readControls() {
                for message in osc?.poll() ?? [] {
                    guard let first = message.values.first else { continue }
                    switch (message.address, first) {
                    case ("/radius", .float(let value)):
                        radius = max(20, min(260, value))
                    case ("/speed", .float(let value)):
                        speed = max(0.05, min(6, value))
                    case ("/hue", .float(let value)):
                        hue = max(0, min(1, value))
                    default:
                        break
                    }
                }

                if let value = midi?.controllerValue(1) {
                    radius = 40 + value * 220
                }
                if let value = midi?.controllerValue(2) {
                    speed = 0.1 + value * 5.0
                }
            }

            private func drawGUI() {
                let panel = context.gui
                panel.begin()
                panel.slider("radius", &radius, min: 20, max: 260, canvas: context.canvas, input: context.input)
                panel.slider("speed", &speed, min: 0.05, max: 6, canvas: context.canvas, input: context.input)
                panel.slider("hue", &hue, min: 0, max: 1, canvas: context.canvas, input: context.input)
                panel.toggle("trails", &showTrails, canvas: context.canvas, input: context.input)
                _ = panel.end()
            }
        }
        """
    }

    private static func appAudioReactive(_ context: TemplateContext) -> String {
        """
        import metaphor

        @main
        final class \(context.moduleName): Sketch {
            private var audio: AudioAnalyzer?

            var config: SketchConfig {
                SketchConfig(width: 1280, height: 720, title: "\(context.projectName.swiftLiteralEscaped)")
            }

            func setup() {
                audio = createAudioInput(fftSize: 1024)
                do {
                    try audio?.start()
                } catch {
                    print("Audio input unavailable: \\(error)")
                }
            }

            func draw() {
                audio?.update()

                let bass = audio?.band(0) ?? 0
                let mids = audio?.band(1) ?? 0
                let highs = audio?.band(2) ?? 0
                let volume = audio?.volume ?? 0

                background(0.015, 0.02, 0.03)
                noStroke()

                let count = 96
                for i in 0..<count {
                    let t = Float(i) / Float(count)
                    let angle = t * Float.pi * 2 + time * (0.4 + bass * 2.0)
                    let wave = sin(angle * 5 + time * 3) * highs * 120
                    let r = 160 + mids * 260 + wave
                    let x = width * 0.5 + cos(angle) * r
                    let y = height * 0.5 + sin(angle) * r
                    fill(0.2 + highs, 0.45 + bass * 0.5, 1.0, 0.72)
                    circle(x, y, 8 + volume * 70)
                }
            }
        }
        """
    }

    private static func appRayTracing(_ context: TemplateContext) -> String {
        """
        import metaphor

        @main
        final class \(context.moduleName): Sketch {
            private var rayTracer: MPSRayTracer?
            private var angle: Float = 0

            var config: SketchConfig {
                SketchConfig(width: 960, height: 540, title: "\(context.projectName.swiftLiteralEscaped)", fps: 30)
            }

            func setup() {
                do {
                    rayTracer = try createRayTracer(width: 640, height: 360)
                } catch {
                    print("Ray tracer unavailable: \\(error)")
                }
            }

            func draw() {
                background(0.02, 0.025, 0.035)
                angle += deltaTime
                renderRayTracedScene()

                if let texture = rayTracer?.outputTexture {
                    image(MImage(texture: texture), 0, 0, width, height)
                } else {
                    fill(1)
                    textSize(16)
                    text("Ray tracing is unavailable on this device.", 24, 32)
                }
            }

            private func renderRayTracedScene() {
                guard let rayTracer else { return }
                let device = context.renderer.device
                rayTracer.clearScene()

                do {
                    let floor = try Mesh.box(device: device, width: 5, height: 0.15, depth: 5)
                    rayTracer.addMesh(floor, transform: float4x4(translation: SIMD3<Float>(0, -1, 0)))

                    let box = try Mesh.box(device: device, width: 1.2, height: 1.2, depth: 1.2)
                    let boxTransform = float4x4(rotationY: angle) * float4x4(rotationX: angle * 0.7)
                    rayTracer.addMesh(box, transform: boxTransform)

                    try rayTracer.buildAccelerationStructure()
                    rayTracer.trace(
                        mode: .ambientOcclusion(samples: 24, radius: 2.5),
                        camera: (
                            eye: SIMD3<Float>(0, 0.4, 4.2),
                            center: SIMD3<Float>(0, 0, 0),
                            up: SIMD3<Float>(0, 1, 0),
                            fov: Float.pi / 3
                        )
                    )
                } catch {
                    print("Ray tracing render failed: \\(error)")
                }
            }
        }
        """
    }

    private static func appSyphon(_ context: TemplateContext) -> String {
        """
        import metaphor

        @main
        final class \(context.moduleName): Sketch {
            var config: SketchConfig {
                SketchConfig(
                    width: 1920,
                    height: 1080,
                    title: "\(context.projectName.swiftLiteralEscaped)",
                    fps: 60,
                    syphonName: "\(context.projectName.swiftLiteralEscaped)",
                    windowScale: 0.5,
                    renderLoopMode: .timer(fps: 60)
                )
            }

            func draw() {
                background(0.01, 0.015, 0.025)
                noStroke()

                for i in 0..<42 {
                    let t = Float(i) / 42.0
                    let angle = time * (0.35 + t) + t * Float.pi * 2
                    let x = width * 0.5 + cos(angle) * width * 0.28
                    let y = height * 0.5 + sin(angle * 1.4) * height * 0.22
                    fill(0.15 + t * 0.6, 0.7, 1.0, 0.72)
                    circle(x, y, 40 + t * 140)
                }
            }
        }
        """
    }

    private static func gitignore() -> String {
        """
        .build/
        .swiftpm/
        DerivedData/
        *.xcodeproj
        *.xcworkspace
        .DS_Store
        Captures/
        Exports/
        """
    }

    private static func readme(_ context: TemplateContext) -> String {
        """
        # \(context.projectName)

        A metaphor sketch generated with:

        ```bash
        metaphor new \(context.projectName) --template \(context.template.rawValue)
        ```

        ## Run

        ```bash
        swift run
        ```

        The sketch entry point is `Sources/\(context.moduleName)/App.swift`.
        """
    }

    private static func defaultPreset(_ context: TemplateContext) -> String {
        """
        {
          "project": "\(context.projectName.swiftLiteralEscaped)",
          "template": "\(context.template.rawValue)",
          "parameters": {}
        }
        """
    }
}
