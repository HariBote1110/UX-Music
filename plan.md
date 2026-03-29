1. **Analyze Vulnerability**
   - The issue is an XSS vulnerability in `src/renderer/js/core/ipc.js` due to unsanitized interpolation of variables (like `file.name`, `file.normalizedName`, `song.title`, `song._reason`) into DOM using `innerHTML`.
   - The memory states we should use a centralized `escapeHtml` utility in `src/renderer/js/ui/utils.js`.

2. **Implement Fix**
   - Add `escapeHtml` to `src/renderer/js/ui/utils.js`.
   - Update `src/renderer/js/core/ipc.js` to import `escapeHtml`.
   - Escape interpolations in `item.innerHTML` template literals within `ipc.js`.
   - Optionally refactor `src/renderer/js/features/mtp-browser.js` to use the centralized `escapeHtml`.

3. **Pre-commit Steps**
   - Run verification scripts (syntax checks, linters).
   - Ensure tests pass and the UI doesn't break.

4. **Submit**
   - Submit the fix with an appropriate PR message explaining the security vulnerability and its resolution.
