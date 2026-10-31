import { test, expect, ConsoleMessage } from '@playwright/test';
import { openLeanNotebook, runCell } from './jupyter';

/**
 * Kernel boot test: the xlean kernel starts in JupyterLite and executes
 * a few cells.  This is the minimal check that a package / prefix is
 * usable (kernelspec found, xlean.js / xlean.wasm / libxeus.so load,
 * Init oleans fetched).
 *
 * The browser console is collected and printed on failure, since a
 * kernel that dies during startup only shows up there.
 */
test.describe('xlean kernel boot', () => {
  const consoleLines: string[] = [];

  test.beforeEach(async ({ page }) => {
    consoleLines.length = 0;
    page.on('console', (msg: ConsoleMessage) =>
      consoleLines.push(`[${msg.type()}] ${msg.text()}`)
    );
    page.on('pageerror', (err) => consoleLines.push(`[pageerror] ${err.message}`));
  });

  test.afterEach(async ({}, testInfo) => {
    if (testInfo.status !== testInfo.expectedStatus) {
      const tail = consoleLines.slice(-200).join('\n');
      await testInfo.attach('browser-console', { body: tail, contentType: 'text/plain' });
      console.log('---- browser console (last 200 lines) ----\n' + tail);
    }
  });

  test('kernel starts and evaluates Lean', async ({ page }) => {
    await openLeanNotebook(page, 'kernel-smoke.ipynb');

    const sum = await runCell(page, '#eval 1 + 1');
    await expect(sum).toContainText('2');

    await runCell(page, 'def x := 21');
    const prod = await runCell(page, '#eval x * 2');
    await expect(prod).toContainText('42');

    const check = await runCell(page, '#check Nat.succ');
    await expect(check).toContainText('Nat.succ');
  });

  test('Std oleans load', async ({ page }) => {
    await openLeanNotebook(page, 'kernel-smoke.ipynb');
    const out = await runCell(
      page,
      'import Std\n#eval (Std.HashMap.ofList [(1, 2), (3, 4)] : Std.HashMap Nat Nat).size'
    );
    await expect(out).toContainText('2');
  });
});
