import AppKit
import QuartzCore

// MARK: - Status overlays

/// アクセントカラー（スピナー）。落ち着いた水色系。
private let statusAccentColor = NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.0, alpha: 1.0)

/// ゆっくり脈動しながら回る有機的なブロブ（不定形の塊）で「処理中」を示す自前スピナー。
/// 輪郭の半径を複数の正弦波の和でゆらすことで、生きているように形が変わり続ける。
/// 形の変形（path のキーフレーム）と全体の回転を CoreAnimation で無限ループさせる。
/// ビルドはバックグラウンドキューで走りメインスレッドは空くため、処理中も止まらない。
private final class SpinnerView: NSView {
    private let blob = CALayer()        // 回転する入れ物
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()   // ブロブ形のマスク（これを変形させる）
    private let diameter: CGFloat

    /// 形のキーフレーム数（多いほど滑らか）。
    private static let morphFrames = 24

    init(diameter: CGFloat, lineWidth: CGFloat, color: NSColor) {
        self.diameter = diameter
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        wantsLayer = true
        layer?.masksToBounds = false

        // 回転する入れ物（中心回りに回すため bounds=自サイズ・position=中心）。
        blob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        blob.position = CGPoint(x: diameter / 2, y: diameter / 2)

        // やわらかい陰影が出るよう、アクセント色の縦グラデーションをブロブ形で切り抜く。
        let light = SpinnerView.lighten(color, by: 0.18)
        gradient.frame = blob.bounds
        gradient.colors = [light.cgColor, color.cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)

        mask.path = SpinnerView.blobPath(diameter: diameter, t: 0)
        mask.fillColor = NSColor.black.cgColor  // マスクは不透明部分だけ通す
        gradient.mask = mask

        blob.addSublayer(gradient)
        layer?.addSublayer(blob)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    /// 変形と回転を開始する（既に動いていれば何もしない）。
    func startAnimating() {
        guard mask.animation(forKey: "morph") == nil else { return }

        // 半径のゆらぎの位相 t を 0→2π まで動かすと元に戻るので、継ぎ目なくループする。
        var paths: [CGPath] = []
        for k in 0...SpinnerView.morphFrames {
            let t = CGFloat(k) / CGFloat(SpinnerView.morphFrames) * 2 * .pi
            paths.append(SpinnerView.blobPath(diameter: diameter, t: t))
        }
        let morph = CAKeyframeAnimation(keyPath: "path")
        morph.values = paths
        morph.duration = 2.8
        morph.repeatCount = .infinity
        morph.isRemovedOnCompletion = false
        mask.add(morph, forKey: "morph")

        // 全体をゆっくり回す（変形とは別周期にして単調さを消す）。
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = 9
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        blob.add(spin, forKey: "spin")
    }

    func stopAnimating() {
        mask.removeAnimation(forKey: "morph")
        blob.removeAnimation(forKey: "spin")
    }

    /// 中心からの半径を複数の正弦波の和でゆらした、滑らかな閉じたブロブ輪郭。
    /// 位相 `t` を進めると形が変わり、`t = 2π` で `t = 0` に戻る。
    private static func blobPath(diameter: CGFloat, t: CGFloat) -> CGPath {
        let segments = 72
        let center = diameter / 2
        let base = diameter * 0.34
        let path = CGMutablePath()
        for i in 0...segments {
            let theta = CGFloat(i) / CGFloat(segments) * 2 * .pi
            // 周回数の異なる波を重ね、逆位相にも動かして有機的なゆらぎにする。
            let wobble = 0.11 * sin(3 * theta + t) + 0.07 * sin(2 * theta + 1.7 - t)
            let r = base * (1 + wobble)
            let point = CGPoint(x: center + r * cos(theta), y: center + r * sin(theta))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// 色を白方向へ `amount`（0–1）混ぜて明るくする。
    private static func lighten(_ color: NSColor, by amount: CGFloat) -> NSColor {
        guard let c = color.usingColorSpace(.deviceRGB) else { return color }
        return NSColor(
            deviceRed: c.redComponent + (1 - c.redComponent) * amount,
            green: c.greenComponent + (1 - c.greenComponent) * amount,
            blue: c.blueComponent + (1 - c.blueComponent) * amount,
            alpha: c.alphaComponent
        )
    }
}

/// フレーム未取得時に窓全体を覆うローディング/エラー表示。暗幕の中央に、回転スピナー
/// （または警告アイコン）とタイトル・詳細を縦に並べるだけのフラットな構成。装飾専用
/// なのでヒットテストは透過。
final class StatusOverlayView: NSView {
    enum Mode { case loading, failed }

    private let spinner = SpinnerView(diameter: 54, lineWidth: 2.5, color: statusAccentColor)
    private let icon = NSImageView()
    private let titleLabel = StatusOverlayView.makeLabel(size: 14, weight: .medium, color: .white)
    private let detailLabel = StatusOverlayView.makeLabel(size: 12, weight: .regular, color: NSColor.white.withAlphaComponent(0.55))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 全体を暗幕で覆うだけ（枠やカードは出さない）。
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor

        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "ビルド失敗")
        icon.contentTintColor = .systemOrange
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        icon.isHidden = true

        let stack = NSStackView(views: [spinner, icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(8, after: titleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 装飾なのでクリック等は背後（ライブ表示）へ透過させる。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(mode: Mode, title: String, detail: String?) {
        switch mode {
        case .loading:
            icon.isHidden = true
            spinner.isHidden = false
            spinner.startAnimating()
        case .failed:
            spinner.stopAnimating()
            spinner.isHidden = true
            icon.isHidden = false
        }
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty
    }

    private static func makeLabel(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        return label
    }
}

/// フレーム取得済みのリロード中などに、直前の絵を覆わず右下へ小さく出す状態バッジ。
final class StatusBadgeView: NSView {
    private let spinner = SpinnerView(diameter: 13, lineWidth: 2, color: .white)
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 6

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .white

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([spinner, label], in: .leading)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 装飾なのでクリック等は背後（ライブ表示）へ透過させる。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// バッジの中身を設定する。`spinning=false` のときはスピナーを隠す（失敗表示など）。
    func configure(spinning: Bool, text: String) {
        label.stringValue = text
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    /// `fittingSize` 計算前にレイアウトを確定させる（右下配置の幅/高さを正しく得るため）。
    func layoutImmediately() {
        layoutSubtreeIfNeeded()
    }
}
