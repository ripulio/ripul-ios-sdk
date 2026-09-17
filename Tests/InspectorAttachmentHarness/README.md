# Inspector composer attachments

Run with an iOS simulator and Xcode 27:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.app/Contents/Developer bash ripul-ios-sdk/Tests/InspectorAttachmentHarness/run.sh <simulator-UDID>
```

The hosted context suites exercise capture, privacy, screenshot selection,
conversation isolation, cancellation and send filtering. The Inspector regression
uses deliberately different tab and source conversation IDs and custom composer
options. Capture alone does not attach; confirmation retains the reviewed draft's
original conversation even after the active tab changes.

The UI test opens the production Inspector over native and web controls, cancels
a preview, changes screenshot inclusion, attaches, and checks the actual composer
chip and its editable preview. It keeps both preview screenshots. This fixture
does not need the broader host-preview harness's JavaScript tool-group fixtures.
