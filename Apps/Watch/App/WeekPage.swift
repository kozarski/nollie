import SwiftUI

/// The weekly note on the wrist: the week, its one line, and each helper's counts, as the iPhone's note says them.
/// Read only; the whole note, with its taps, is in Nollie on the iPhone.
struct WeekPage: View {
    let note: WatchWire.WeekNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.teal)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WatchWords.yourWeek)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(note.range)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(note.headline)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(note.helpers.indices, id: \.self) { index in
                    let helper = note.helpers[index]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(helper.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(helper.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                if note.more > 0 {
                    Text(WatchWords.more(note.more))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(WatchWords.fullNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scenePadding(.horizontal)
        }
        .accessibilityIdentifier("watch.week")
    }
}
