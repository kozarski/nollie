import SwiftUI

/// The last Night shift note: what the crew did while nobody watched, in the words the iPhone's card
/// uses. Read only; the whole card, with each Why, is in Nollie on the iPhone.
struct NightPage: View {
    let note: WatchWire.NightNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(note.needsLook ? .orange : .indigo)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WatchWords.nightShift)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let since = note.since {
                        Text(since)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(note.counts)
                    .font(.body)
                    .foregroundStyle(note.needsLook ? .orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(note.runs.indices, id: \.self) { index in
                    let run = note.runs[index]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(run.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
                if note.more > 0 {
                    Text(WatchWords.more(note.more))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scenePadding(.horizontal)
        }
        .accessibilityIdentifier("watch.night")
    }
}
