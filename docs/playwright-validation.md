# Playwright frontend validation

Playwright is Squad's frontend-validation toolset in three forms: an MCP server for interactive validation inside the agent harness, a CLI for one-off scripted checks, and a project-side CI pattern for automatic PR visual validation.
The [playwright-mcp README](https://github.com/microsoft/playwright-mcp) and [playwright.dev](https://playwright.dev) own the tool mechanics; this doc covers which form to use when.

## Playwright MCP for interactive validation

The Playwright MCP server is already registered in the pi agent MCP config (`~/.pi/agent/mcp.json`) as `npx -y @playwright/mcp@latest`, so every operator launched on the pi harness gets its `browser_*` tools automatically.
The core loop is `browser_navigate` to a URL, `browser_snapshot` to read the page as an accessibility tree, `browser_click` and `browser_type` to act on snapshot references, and `browser_take_screenshot` to capture each step as evidence.
Snapshots are structured text, not pixels, so action targets come from the tree and no vision model is needed.
`browser_fill_form`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_console_messages`, and `browser_network_requests` cover the common validation extras.
Server options such as headless mode, browser channel, viewport size, and isolated sessions belong to the playwright-mcp README, not this doc.
Use the MCP flow when the validation is interactive and exploratory: walking a signup or checkout flow, filling forms, and capturing screenshots of each step.
Use sq-browser (chrome-devtools) when the work is debugging or performance: live console inspection, network waterfalls, and DOM and CSS investigation against a running page.
For general one-off browsing that is neither, sq-browser stays the token-efficient default.

## Playwright CLI for scripted validation

The CLI runs on demand through npx with no project setup.
`npx playwright screenshot --full-page <url> <file>` captures a full-page screenshot, and `npx playwright codegen <url>` records interactions into a test.
A project that wants repeatable validation adds `@playwright/test` as a dev dependency and runs `npx playwright install chromium` for the browser.
The playwright.dev CLI and test-runner docs own the exact flags and APIs.

## Automatic PR visual validation

The project-side pattern is a CI job that boots the app, walks the key flows with Playwright, captures full-page screenshots per flow, uploads the screenshots as workflow artifacts, and comments the image links on the PR.
The reference implementation is the career-coach-pr-visual-validation job landing in runecraftai/career-coach's CI.
