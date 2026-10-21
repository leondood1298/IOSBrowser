import SwiftUI

/// The first-launch tour: four cards on what the browser does, then "Start Browsing".
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0

    private struct Card: Identifiable {
        let id: Int
        let symbol: String
        let title: String
        let text: String
    }

    private let cards = [
        Card(
            id: 0, symbol: "hand.raised.fill", title: "Private by Default",
            text: "Trackers are blocked with Firefox Focus's lists. Private tabs leave nothing behind: tap the trash "
                + "to erase them. Lock the whole app, or just private tabs, with Face ID."),
        Card(
            id: 1, symbol: "arrow.down.circle.fill", title: "Save What You Find",
            text: "Downloads keep going in the background, with their progress on the Lock Screen. The media button "
                + "in the address bar saves video and audio from pages, streams included."),
        Card(
            id: 2, symbol: "folder.fill", title: "Your Files",
            text: "Everything you save is in Files: sort and search it, make and open ZIP files (RAR and 7-Zip "
                + "open too), and get deleted files back from the Bin."),
        Card(
            id: 3, symbol: "play.rectangle.fill", title: "Watch and Read",
            text: "Images and PDFs turn pages instantly. Videos play in picture in picture, music keeps playing in "
                + "the background, and VLC opens the formats nothing else will."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(cards) { card in
                    VStack(spacing: 18) {
                        Image(systemName: card.symbol)
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(card.title)
                            .font(.title.bold())
                        Text(card.text)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 40)
                    .tag(card.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < cards.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(page < cards.count - 1 ? "Next" : "Start Browsing")
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboardingNextButton")
        }
        .padding(.vertical, 32)
        .interactiveDismissDisabled()
    }
}
