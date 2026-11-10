import SwiftUI

/// Board tasks that are waiting for the person: what each one is and which helper holds it. Read only;
/// the answer is given in Nollie on the iPhone, where the whole task is.
struct BoardPage: View {
    let note: WatchWire.BoardNote

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
                Text(WatchWords.needsYourHelp)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(note.tasks.indices, id: \.self) { index in
                    let task = note.tasks[index]
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title)
                            .font(.headline)
                            .lineLimit(3)
                        if !task.detail.isEmpty {
                            Text(task.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                if note.more > 0 {
                    Text(WatchWords.more(note.more))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(WatchWords.answerOnPhone)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scenePadding(.horizontal)
        }
        .accessibilityIdentifier("watch.board")
    }
}
