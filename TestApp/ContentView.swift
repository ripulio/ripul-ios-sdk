import SwiftUI

struct ContentView: View {
    @State private var tapCount = 0

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "swift")
                .font(.system(size: 80))
                .foregroundStyle(.orange)

            Text("Hello, World!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Tap count: \(tapCount)")
                .font(.title2)
                .foregroundStyle(.secondary)

            Button("Tap Me") {
                tapCount += 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
