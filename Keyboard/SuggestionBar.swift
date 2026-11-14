import UIKit

/// Barra de sugestões que trata o toque diretamente (como as teclas).
/// Botões comuns do iOS às vezes "perdiam" o toque dentro do teclado.
final class SuggestionBar: UIView {
    var onTap: ((Int) -> Void)?
    var onLongPress: ((Int) -> Void)?

    private var labels: [UILabel] = []
    private var count = 0
    private var highlights: [Bool] = []
    private var pressedIndex: Int?
    private var timer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.001) // capta toques no vão
        for _ in 0..<3 {
            let l = UILabel()
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 17)
            l.textColor = .label
            l.lineBreakMode = .byTruncatingTail
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.7
            l.layer.cornerRadius = 8
            l.clipsToBounds = true
            addSubview(l)
            labels.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard count > 0 else { return }
        let w = bounds.width / CGFloat(count)
        for (i, l) in labels.enumerated() {
            l.frame = i < count ? CGRect(x: CGFloat(i) * w + 2, y: 0, width: w - 4, height: bounds.height) : .zero
        }
    }

    func set(_ items: [(title: String, highlight: Bool)]) {
        count = min(items.count, 3)
        highlights = items.prefix(3).map { $0.highlight }
        for (i, l) in labels.enumerated() {
            if i < count {
                l.text = items[i].title
                l.font = items[i].highlight ? .boldSystemFont(ofSize: 17) : .systemFont(ofSize: 17)
                l.isHidden = false
            } else {
                l.text = nil
                l.isHidden = true
            }
        }
        refreshColors()
        setNeedsLayout()
    }

    private func refreshColors() {
        for (i, l) in labels.enumerated() where i < count {
            if i == pressedIndex {
                l.backgroundColor = KeyView.pressedColor
            } else {
                l.backgroundColor = highlights[i] ? KeyView.normalColor.withAlphaComponent(0.6) : .clear
            }
        }
    }

    private func index(at p: CGPoint) -> Int? {
        guard count > 0, bounds.width > 0 else { return nil }
        let i = Int(p.x / (bounds.width / CGFloat(count)))
        return min(max(i, 0), count - 1)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let i = index(at: t.location(in: self)) else { return }
        pressedIndex = i
        refreshColors()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, let i = self.pressedIndex else { return }
            self.pressedIndex = nil
            self.refreshColors()
            self.onLongPress?(i)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }

    // se o sistema cancelar o toque, ainda vale como toque
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish() }

    private func finish() {
        timer?.invalidate()
        guard let i = pressedIndex else { return }
        pressedIndex = nil
        refreshColors()
        onTap?(i)
    }
}
