# Native view context editor

On iPhone, open **Solution management > View Contexts**. This SDK screen follows the solution-context management flow: a searchable native list, an editor sheet, and the existing Clerk-authenticated `/api/admin/view-contexts` CRUD API.

The editor supports identity, available tab IDs and default tab, all current `ViewContextFeatures` fields, and custom chat action buttons with visibility conditions and ordering. Tab IDs and prompt collection IDs refer to the solution's existing configuration. Image fields accept hosted image URLs. System contexts can be inspected but cannot be saved or deleted.

Feature controls preserve the difference between an absent setting (Default), an explicit false, and an empty custom allowlist or button list. The client retains the complete feature dictionary when editing so settings added by other clients survive. Keep `RipulViewContextField.all` aligned with `chrome-extension/src/config/interfaces.ts` when introducing new feature controls.

Validation covers context identifiers, required names and tabs, default-tab membership, non-negative finite numeric values, and unique action IDs with required labels and event names. Save errors keep the form open, and closing a changed form requires discarding its changes explicitly.

Validation: `swift test --filter ViewContextsClientTests` checks feature preservation, malformed records, system metadata, and missing authentication. The screen must also be compiled through the RipulApp iOS Xcode scheme; Swift package tests alone do not compile iOS-only SwiftUI views.
