# App working directory

Open the Agents session-list menu and choose **App Working Directory…**. Select a folder from the connected host's directory list. The choice is saved in this app's persistent web data container, so WAC and Ripul can use different defaults without embedding a developer's local path in either application.

Every new session reads the saved choice when it is created, including CLI provider shortcuts, the model picker, ordinary New Chat, and prompt-based starts. The first message carries that directory to the host. An explicitly supplied destination takes precedence. Changing the app default does not move existing sessions; their per-session directory picker remains independent.

Choose **Default** to remove the saved choice and let future sessions use the host default. Loading and saving failures are shown in the picker. No repository is inferred from the app's name.

This is the existing shared Work in preference, now surfaced in the session-list menu rather than the project-filter menu. Plans use the same app preference. Custom `AgentConfiguration.websiteDataStore` profiles retain separate preferences; the standard persistent store keeps the choice across app launches. Hosts choosing a nonpersistent web data store deliberately opt out of persistence.
