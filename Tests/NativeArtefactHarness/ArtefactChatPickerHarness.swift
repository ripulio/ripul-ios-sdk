import PhotosUI
import SwiftUI
import WebKit
@testable import RipulAgent

/// Exercises the shipped native composer and picker against a deterministic JS transport.
struct ArtefactChatPickerHarness: View {
  @StateObject private var model = PickerHarnessModel()
  @State private var draft = "Keep my draft"
  @State private var images: [NativeImageAttachment] = []
  @State private var photos: [PhotosPickerItem] = []
  @State private var show = false
  @State private var modelRequests = 0
  var body: some View {
    VStack {
      Text("Draft: \(draft)").accessibilityIdentifier("PickerHarness.draft")
      Text("Model requests: \(modelRequests)").accessibilityIdentifier("PickerHarness.model")
      Text(model.receipt).accessibilityIdentifier("PickerHarness.receipt")
      Spacer()
      NativeChatInput(text: $draft, imageAttachments: $images, selectedPhotos: $photos,
        onSubmit: { modelRequests += 1 }, onAddArtefact: { show = true })
    }
    .sheet(isPresented: $show, onDismiss: { Task { await model.refresh() } }) {
      ArtefactChatPicker(bridge: model.bridge, chatID: "picker-fixture-chat")
    }
  }
}
@MainActor private final class PickerHarnessModel: ObservableObject {
  let bridge = AgentBridge()
  let web = WKWebView()
  @Published var receipt = "No card"
  init() {
    bridge.attach(to: web)
    web.loadHTMLString("""
      <script>
      window.posts={};window.failFirst=true;
      window.__ripulArtefactChat=async(chatId,op,input)=>{
        if(chatId!=='picker-fixture-chat')throw new Error('Wrong chat');
        if(op==='catalog')return [{id:'planner',title:'Team planner',latestRevision:2},{id:'map',title:'London map',latestRevision:1}];
        if(op==='choose')return {id:input.id,title:'Team planner',revision:2,surfaces:['widget','page'],canShare:true};
        if(op==='teams')return [{teamId:'ops',teamName:'Operations'}];
        if(op==='post'){
          window.posts[input.presentationId]=input;
          if(window.failFirst){window.failFirst=false;throw new Error('Lost acknowledgement');}
          return {success:true};
        }
        throw new Error('Unknown action');
      };
      </script>
      """, baseURL: URL(string: "https://fixture.invalid"))
  }
  func refresh() async {
    let result = try? await bridge.callAsyncJavaScript("return 'Cards: '+Object.keys(window.posts).length+'; revision: '+(Object.values(window.posts)[0]?.revision || 'none')")
    receipt = result as? String ?? "No reply"
  }
}
