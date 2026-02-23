import SwiftUI

/// A UITableView subclass that can report its content height as intrinsic size,
/// allowing SwiftUI to size it correctly when scroll is disabled.
/// When scrolling is enabled, it defers to the proposed size so the view
/// stays within the visible area and scrolls normally.
class IntrinsicTableView: UITableView {
    var reportIntrinsicHeight = true

    override var contentSize: CGSize {
        didSet {
            if reportIntrinsicHeight && oldValue.height != contentSize.height {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        guard reportIntrinsicHeight else {
            return super.intrinsicContentSize
        }
        return CGSize(width: UIView.noIntrinsicMetric, height: contentSize.height)
    }
}

struct ReorderableMediaList: UIViewRepresentable {
    @Binding var items: [ListItem]
    var isEditing: Bool = false
    var isCompact: Bool = false
    var isScrollEnabled: Bool = true
    let subtitleProvider: (ListItem) -> String?
    var onDelete: ((String) -> Void)?
    var onMove: (() -> Void)?

    func makeUIView(context: Context) -> IntrinsicTableView {
        let tv = IntrinsicTableView(frame: .zero, style: .plain)
        tv.backgroundColor = .clear
        tv.separatorStyle = .none
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "MediaCell")
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator
        tv.isScrollEnabled = isScrollEnabled
        tv.reportIntrinsicHeight = !isScrollEnabled
        tv.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: isScrollEnabled ? 20 : 0, right: 0)

        context.coordinator.dataItems = items
        return tv
    }

    func updateUIView(_ tv: IntrinsicTableView, context: Context) {
        let coord = context.coordinator
        coord.parent = self

        tv.setEditing(isEditing, animated: true)
        tv.isScrollEnabled = isScrollEnabled
        tv.reportIntrinsicHeight = !isScrollEnabled
        tv.allowsSelectionDuringEditing = false
        tv.allowsSelection = !isEditing

        let newIDs = items.compactMap { $0.media?.id }
        let currentIDs = coord.dataItems.compactMap { $0.media?.id }
        if newIDs != currentIDs {
            coord.dataItems = items
            tv.reloadData()
        } else if coord.needsReload {
            coord.needsReload = false
            coord.dataItems = items
            tv.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var parent: ReorderableMediaList
        var dataItems: [ListItem] = []
        var needsReload = false

        init(_ parent: ReorderableMediaList) {
            self.parent = parent
        }

        // MARK: - Data source

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            dataItems.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "MediaCell", for: indexPath)
            let item = dataItems[indexPath.row]
            cell.contentConfiguration = UIHostingConfiguration {
                MediaCardView(
                    title: item.media?.title ?? "",
                    subtitle: parent.subtitleProvider(item),
                    imageURL: item.media?.thumbnailURL,
                    networks: item.media?.networks ?? [],
                    providerCategories: item.media?.providerCategories ?? [:],
                    isWatched: item.isWatched,
                    watchedToggleAction: { _ in },
                    isCompact: parent.isCompact,
                    voteAverage: item.media?.voteAverage,
                    genres: item.media?.genres ?? [],
                    nextAirDate: item.tvShow?.nextEpisodeAirDate
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .margins(.all, EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6))
            .background(Color.clear)
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            return cell
        }

        // MARK: - Edit mode (handles + delete)

        func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
            true
        }

        func tableView(_ tableView: UITableView, moveRowAt src: IndexPath, to dst: IndexPath) {
            let item = dataItems.remove(at: src.row)
            dataItems.insert(item, at: dst.row)
            parent.items = dataItems
            parent.onMove?()
        }

        func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
            if editingStyle == .delete {
                let item = dataItems.remove(at: indexPath.row)
                tableView.deleteRows(at: [indexPath], with: .automatic)
                if let id = item.media?.id {
                    parent.onDelete?(id)
                }
            }
        }

        func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
            .delete
        }

        func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
            false
        }
    }
}
