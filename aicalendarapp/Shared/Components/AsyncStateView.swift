import SwiftUI

struct AsyncStateView<Value, Content: View>: View {
    let state: LoadableState<Value>
    let retry: (() -> Void)?
    private let content: (Value) -> Content

    init(
        state: LoadableState<Value>,
        retry: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.state = state
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let value):
            content(value)
        case .failed(let error):
            VStack(spacing: 12) {
                Text(error.localizedDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AppTheme.textSecondary)

                if let retry {
                    Button("Try Again", action: retry)
                        .buttonStyle(AppPrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppTheme.screenPadding)
        }
    }
}
