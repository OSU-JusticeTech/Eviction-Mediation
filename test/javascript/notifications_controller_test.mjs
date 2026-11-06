import { test } from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"

test("visible chat stays present without window focus, but hidden chats and navigation clear it", async (t) => {
  const source = (await readFile(new URL("../../app/javascript/controllers/notifications_controller.js", import.meta.url), "utf8"))
    .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
  const { default: NotificationsController } = await import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`)
  const calls = []
  let intersectionChanged
  let heartbeat
  let focused = false
  let disconnected = false
  const replacements = {
    crypto: { randomUUID: () => "12345678-1234-1234-1234-123456789abc" },
    document: { hidden: false, hasFocus: () => focused, querySelector: () => ({ content: "csrf" }),
      getElementById: () => ({ dataset: { conversationId: "42", currentUserRole: "Tenant" }, closest: () => ({}) }) },
    window: { setInterval: (callback) => { heartbeat = callback; return 1 }, clearInterval: () => {} },
    IntersectionObserver: class {
      constructor(callback) { intersectionChanged = callback }
      observe() {}
      disconnect() { disconnected = true }
    },
    fetch: async (url, options) => {
      calls.push({ url, method: options.method, ...JSON.parse(options.body) })
      return { ok: true }
    }
  }
  for (const [key, value] of Object.entries(replacements)) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, key)
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
    t.after(() => descriptor ? Object.defineProperty(globalThis, key, descriptor) : delete globalThis[key])
  }

  const controller = new NotificationsController()
  controller.presenceUrlValue = "/notifications/presence"
  let reloads = 0
  let menuOpen = false
  let src = ""
  controller.element = { querySelector: () => menuOpen ? {} : null, hasAttribute: () => false, reload: () => { reloads++ },
    get src() { return src }, set src(value) { src = value; reloads++ } }
  controller.connect()

  intersectionChanged([{ isIntersecting: true }])
  await controller.pendingRequest
  assert.equal(calls.at(-1)?.method, "PATCH", "A visible chat in an unfocused window must be registered")
  assert.equal(calls.at(-1).conversation_id, 42, "Presence must identify the exact chat")

  focused = true
  controller.publishPresence()
  focused = false
  controller.publishPresence()
  heartbeat()
  await controller.pendingRequest
  assert.ok(calls.every(call => call.method === "PATCH"), "Losing window focus must not clear visible chat presence")

  document.hidden = true
  controller.publishPresence()
  await controller.pendingRequest
  assert.equal(calls.at(-1).method, "DELETE", "Switching to another tab must restore alerts")
  const count = calls.length
  heartbeat()
  await controller.pendingRequest
  assert.equal(calls.length, count, "A background tab must not renew presence")

  document.hidden = false
  intersectionChanged([{ isIntersecting: false }])
  await controller.pendingRequest
  assert.equal(calls.length, count, "A hidden chat panel must not register presence")

  intersectionChanged([{ isIntersecting: true }])
  controller.disconnect()
  await controller.pendingRequest
  assert.deepEqual(calls.slice(-2).map(call => call.method), ["PATCH", "DELETE"])
  assert.equal(disconnected, true)

  // Outside chat, the same controller only polls the bell every 30 seconds.
  document.getElementById = () => null
  const bell = new NotificationsController()
  bell.element = controller.element
  bell.menuUrlValue = "/notifications/menu"
  bell.connect()
  heartbeat(); heartbeat()
  assert.equal(reloads, 0)
  heartbeat()
  assert.equal(reloads, 1)
  menuOpen = true
  heartbeat(); heartbeat(); heartbeat()
  assert.equal(reloads, 1, "An open dropdown must stay stable")
  menuOpen = false
  document.hidden = true
  heartbeat(); heartbeat(); heartbeat()
  assert.equal(reloads, 1, "A hidden tab must not refresh the bell")
  document.hidden = false
  bell.resume()
  assert.equal(reloads, 2, "Returning to the tab must refresh the bell")
  bell.disconnect()
})
