import UIKit

/// Painel de emojis próprio (o iOS não deixa um teclado abrir o painel de emojis do sistema).
final class EmojiPanel: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onPick: ((String) -> Void)?

    private var sections: [[String]] = []
    private var icons: [String] = []
    private let collection: UICollectionView
    private let tabs = UIStackView()

    static let categories: [(String, String)] = [
        ("😀", "😀😃😄😁😆😅😂🤣🥲☺️😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🥸🤩🥳😏😒😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🤗🤔🫡🤭🫢🤫🤥😶😐😑😬🙄😯😦😧😮😲🥱😴🤤😪😵🤐🥴🤢🤮🤧😷🤒🤕🤑🤠😈👿👻💀☠️👽🤖💩😺😸😹😻😼😽🙀😿😾"),
        ("👍", "👍👎👌✌️🤞🤟🤘🤙👈👉👆👇☝️✋🤚🖐️🖖👋🤝🙏✍️💪👏🙌👐🤲🫶👀🧠👶🧒👦👧🧑👨👩🧓👴👵👷🧑‍🔧🧑‍💻🧑‍🏭👮🧑‍⚕️🧑‍🍳🧑‍🎓🧑‍🌾🏃🚶🧍🙋🙆🙅🤷🤦💁"),
        ("❤️", "❤️🧡💛💚💙💜🖤🤍🤎💔❣️💕💞💓💗💖💘💝💯💢💥💫💦💨🔥✨⭐🌟💤🎉🎊🎈"),
        ("🐶", "🐶🐱🐭🐹🐰🦊🐻🐼🐨🐯🦁🐮🐷🐸🐵🐔🐧🐦🐤🦆🦅🦉🐴🦄🐝🦋🐌🐞🐢🐍🐙🐠🐟🐬🐳🌵🌲🌳🌴🌱🌿☘️🍀🍁🍂🌷🌹🌺🌸🌼🌻🌞🌝🌙☀️⛅☁️🌧️⛈️🌩️❄️☃️🌈🌊"),
        ("🍔", "🍏🍎🍐🍊🍋🍌🍉🍇🍓🍒🍑🥭🍍🥥🥝🍅🥑🥦🥕🌽🌶️🥔🍞🧀🥚🍳🥓🥩🍗🍖🌭🍔🍟🍕🥪🌮🌯🍝🍜🍲🍛🍣🍱🍚🍙🍰🎂🍮🍭🍬🍫🍿🍩🍪☕🍵🥤🍺🍻🥂🍷🥃🍹"),
        ("⚽", "⚽🏀🏈⚾🎾🏐🎱🏓🏸🥊🏋️🚴🏊🎮🎲🎯🎸🎧🎤🎬🏆🥇🚗🚕🚙🚌🚓🚑🚒🚚🚜🏍️🚲✈️🚀🚁⛵🚢🏠🏢🏭🏥🏦🏫⛪🏖️⛰️"),
        ("💡", "⚡🔋🔌💡🔦🕯️🧯🛠️🔧🔨⚙️🧰🔩⛓️🧲📱💻⌨️🖥️🖨️📷📹📞☎️📺⏰⏱️⌛📅📆📋📌📎✂️📝✏️📏📐📁📂📊📈📉🔒🔓🔑💰💵💳🧾📦✉️📧🎁💊🩺"),
        ("✅", "✅☑️✔️❌❎➕➖➗✖️❓❗‼️⁉️⚠️🚫⛔🔴🟠🟡🟢🔵🟣⚫⚪🟥🟩🟦⬆️⬇️⬅️➡️↩️🔄🔁▶️⏸️⏹️🔊🔇🔔🔕💬💭🆗🆕🆘")
    ]

    init(recents: [String]) {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 42, height: 42)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        layout.sectionInset = UIEdgeInsets(top: 2, left: 0, bottom: 8, right: 0)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)

        icons = ["🕘"] + Self.categories.map { $0.0 }
        sections = [recents] + Self.categories.map { Array($0.1).map(String.init) }

        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(EmojiCell.self, forCellWithReuseIdentifier: "c")
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)

        tabs.axis = .horizontal
        tabs.distribution = .fillEqually
        tabs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabs)
        for (i, icon) in icons.enumerated() {
            let b = UIButton(type: .system)
            b.setTitle(icon, for: .normal)
            b.titleLabel?.font = .systemFont(ofSize: 18)
            b.tag = i
            b.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabs.addArrangedSubview(b)
        }

        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: topAnchor),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: tabs.topAnchor),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabs.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabs.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    @objc private func tabTapped(_ sender: UIButton) {
        let s = sender.tag
        guard s < sections.count, !sections[s].isEmpty else { return }
        collection.scrollToItem(at: IndexPath(item: 0, section: s), at: .top, animated: false)
    }

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath) as! EmojiCell
        cell.label.text = sections[indexPath.section][indexPath.item]
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPick?(sections[indexPath.section][indexPath.item])
    }
}

private final class EmojiCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 30)
        label.textAlignment = .center
        label.frame = contentView.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }
    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? UIColor.systemGray4 : .clear }
    }
}
