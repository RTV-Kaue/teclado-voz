import UIKit

enum KeyboardLayer { case letters, numbers, symbols }

enum KeyKind: Equatable {
    case char(String)
    case shift, delete, space, ret
    case layer(KeyboardLayer)
}

/// Uma tecla desenhada. O toque é tratado pelo KeysContainer (tecla mais próxima),
/// assim os espaços entre as teclas também contam.
final class KeyView: UIView {
    let kind: KeyKind
    let isSpecial: Bool
    let alternates: [String]
    private let label = UILabel()
    private let icon = UIImageView()

    var highlighted = false { didSet { refreshColor() } }
    var active = false { didSet { refreshColor() } }

    static let normalColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    static let specialColor = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1)
                                       : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1)
    }
    static let pressedColor = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.62, alpha: 1)
                                       : UIColor(red: 0.80, green: 0.82, blue: 0.86, alpha: 1)
    }

    init(kind: KeyKind, title: String?, symbol: String?, special: Bool, alternates: [String], fontSize: CGFloat) {
        self.kind = kind
        self.isSpecial = special
        self.alternates = alternates
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0

        label.textAlignment = .center
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.font = special ? .systemFont(ofSize: max(14, fontSize * 0.68)) : .systemFont(ofSize: fontSize)
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: fontSize * 0.8, weight: .regular)

        for v in [label, icon] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        if let symbol { setSymbol(symbol) } else { setTitle(title ?? "") }
        refreshColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Sombra com caminho pronto: muito mais leve para desenhar
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    func setTitle(_ t: String) {
        label.text = t
        label.isHidden = false
        icon.isHidden = true
    }

    func setSymbol(_ s: String) {
        icon.image = UIImage(systemName: s)
        icon.isHidden = false
        label.isHidden = true
    }

    private func refreshColor() {
        if highlighted {
            backgroundColor = KeyView.pressedColor
        } else if active {
            backgroundColor = KeyView.normalColor
        } else {
            backgroundColor = isSpecial ? KeyView.specialColor : KeyView.normalColor
        }
    }
}

protocol KeysContainerDelegate: AnyObject {
    func keyTouchBegan(_ touch: UITouch, key: KeyView, at p: CGPoint)
    func keyTouchMoved(_ touch: UITouch, at p: CGPoint)
    func keyTouchEnded(_ touch: UITouch, cancelled: Bool)
}

/// Recebe todos os toques e entrega para a tecla mais próxima.
final class KeysContainer: UIView {
    weak var delegate: KeysContainerDelegate?
    var keys: [KeyView] = []
    var passthrough: [UIView] = []   // botões reais (ex.: globo) que recebem o toque direto

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor.black.withAlphaComponent(0.001) // capta toques nos vãos
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for v in passthrough where !v.isHidden && v.window != nil {
            if v.bounds.contains(convert(point, to: v)) { return v }
        }
        return bounds.contains(point) ? self : nil
    }

    func key(at p: CGPoint) -> KeyView? {
        var best: KeyView?
        var bestD = CGFloat.greatestFiniteMagnitude
        for k in keys where k.window != nil {
            let f = k.convert(k.bounds, to: self)
            if f.contains(p) { return k }
            let dx = max(f.minX - p.x, 0, p.x - f.maxX)
            let dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let d = dx * dx + dy * dy
            if d < bestD { bestD = d; best = k }
        }
        return bestD < 40 * 40 ? best : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if let k = key(at: p) { delegate?.keyTouchBegan(t, key: k, at: p) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { delegate?.keyTouchMoved(t, at: t.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { delegate?.keyTouchEnded(t, cancelled: false) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { delegate?.keyTouchEnded(t, cancelled: true) }
    }
}
