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

The UI tests open the production Inspector over native and web controls, cancel
a preview, change screenshot inclusion, attach, and check the actual composer
chip and its editable preview. They keep the preview screenshots. This fixture
does not need the broader host-preview harness's JavaScript tool-group fixtures.

The minimized-chat variant mounts the production agent window and compact row,
then uses the same no-bridge `toggle(in:)` entry point as a host's shake gesture.
It verifies that native and web captures reach that existing agent's composer.
The hosted regression also checks that dismissing the agent prevents attaching
to its old conversation.
