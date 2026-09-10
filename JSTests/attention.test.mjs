import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";

import { bindings, documentShim, plain, readFragment } from "./support/fragments.mjs";

const source = readFragment("main");
const start = source.indexOf("// Attention describes unseen work");
const end = source.indexOf("function renderWorkspace", start);
assert.ok(start >= 0 && end > start, "attention helpers must be present in the shipped client");

function attentionHarness(items = []) {
  const { FakeNode, document } = documentShim();
  const elements = Object.fromEntries([
    "attentionSummary", "attentionCount", "attentionDetail", "attentionNext",
    "sessionAttentionBanner", "sessionAttentionTitle", "sessionAttentionDetail",
    "attentionOpen", "attentionMarkRead", "attentionReadStatus",
  ].map((name) => {
    const node = new FakeNode("div");
    node.dataset = {};
    node.disabled = false;
    node.contains = (target) => node === target || node.children.includes(target);
    return [name, node];
  }));
  const createElement = document.createElement;
  document.createElement = (tag) => {
    const element = createElement(tag);
    element.dataset = {};
    return element;
  };
  const calls = [];
  elements.attentionSummary.focus = () => calls.push(["summary-focus"]);
  const context = vm.createContext({
    document, ...elements,
    sessionState: new Map(items.map((item) => [item.id, item])),
    selected: null,
    selectionGeneration: 0,
    CSS: { escape: (value) => value },
    sessions: {
      querySelector: (selector) => ({
        scrollIntoView: () => calls.push(["scroll", selector]),
        focus: () => calls.push(["focus", selector]),
      }),
    },
    transcript: { focus: () => calls.push(["transcript-focus"]) },
    userInput: { querySelector: () => ({ focus: () => calls.push(["question-focus"]) }) },
    setViewMode: (mode) => calls.push(["view", mode]),
    control: async (message) => { calls.push(["control", plain(message)]); return { ok: true }; },
  });
  context.selectSession = (id) => {
    calls.push(["select", id]);
    context.selected = id;
    context.selectionGeneration += 1;
  };
  vm.runInContext(source.slice(start, end), context, { filename: "main-attention.js" });
  return {
    context, elements, calls, document,
    ...bindings(context, [
      "sessionAttention", "attentionSessions", "renderAttentionSummary", "renderSelectedAttention",
      "openSelectedAttention", "selectNextAttention", "markSelectedAttentionRead", "renderSessionButton",
    ]),
  };
}

const session = (id, fields = {}) => ({
  id, title: id, status: "idle", ready: false, unread: false,
  background: false, scheduled: false, promptable: true, ...fields,
});

test("only questions, waiting, unseen completions, and notifications need attention", () => {
  const { sessionAttention } = attentionHarness();
  for (const item of [
    null, session("idle"), session("running", { status: "running" }),
    session("background", { background: true }),
    session("scheduled", { scheduled: true }),
    session("stale-ready", { status: "running", ready: true }),
  ]) {
    assert.equal(sessionAttention(item), null);
  }
  for (const field of ["pendingUserInputs", "pendingElicitations"]) {
    assert.deepEqual(plain(sessionAttention(session("question", {
      status: "running", background: true, scheduled: true, ready: true, unread: true,
      [field]: [{ requestId: "request" }],
    }))), { kind: "waiting", label: "Needs input", mode: "conversation" });
  }
  assert.deepEqual(plain(sessionAttention(session("permission", {
    status: "waiting", ready: true, unread: true, pendingUserInputs: [], pendingElicitations: [],
  }))), { kind: "waiting", label: "Needs input", mode: "terminal" });
  assert.equal(sessionAttention(session("ready", {
    ready: true, unread: true, scheduled: true, background: true, promptable: true,
  })).kind, "ready");
  assert.equal(sessionAttention(session("notification", {
    status: "running", unread: true,
  })).kind, "unread");
});

test("summary counts sessions once, prioritizes waiting, and updates the browser title", () => {
  const items = [
    session("ready", { ready: true, unread: true }),
    session("idle"),
    session("question", { pendingUserInputs: [{}] }),
    session("unread", { unread: true }),
    session("permission", { status: "waiting" }),
  ];
  const harness = attentionHarness(items);
  harness.renderAttentionSummary();
  assert.equal(harness.elements.attentionCount.textContent, "Needs attention (4)");
  assert.equal(harness.elements.attentionDetail.textContent, "2 waiting for input \u00b7 2 with unseen activity");
  assert.equal(harness.document.title, "(4) Copilot Projects");
  assert.deepEqual(plain(harness.attentionSessions().map((item) => item.id)),
    ["question", "permission", "ready", "unread"]);
  assert.deepEqual([...harness.context.sessionState.keys()], items.map((item) => item.id),
    "priority navigation must not reorder the workspace");

  // Repeated snapshots must not mutate the stable live-region text.
  for (const element of [harness.elements.attentionCount, harness.elements.attentionDetail]) {
    Object.defineProperty(element, "textContent", {
      get: () => element._text,
      set: () => assert.fail("unchanged summary was rewritten"),
      configurable: true,
    });
  }
  harness.renderAttentionSummary();
});

test("cleared and removed sessions reset the count and title without flagging background work", () => {
  const harness = attentionHarness([session("ready", { ready: true })]);
  harness.renderAttentionSummary();
  harness.context.sessionState.set("ready", session("ready", { background: true, scheduled: true }));
  harness.renderAttentionSummary();
  assert.equal(harness.document.title, "Copilot Projects");
  assert.equal(harness.elements.attentionCount.textContent, "All caught up");
  assert.equal(harness.elements.attentionNext.disabled, true);
  assert.equal(harness.elements.attentionSummary.dataset.attention, "none");
  harness.context.sessionState.clear();
  harness.renderAttentionSummary();
  harness.selectNextAttention();
  assert.deepEqual(harness.calls, []);
});

test("Next cycles through waiting sessions then unseen activity, including wraparound", () => {
  const harness = attentionHarness([
    session("ready", { ready: true }),
    session("permission", { status: "waiting" }),
    session("question", { pendingElicitations: [{}] }),
  ]);
  for (const id of ["permission", "question", "ready", "permission"]) {
    harness.selectNextAttention();
    assert.equal(harness.context.selected, id);
  }
  harness.context.sessionState.delete("question");
  harness.context.sessionState.delete("ready");
  harness.calls.length = 0;
  harness.selectNextAttention();
  assert.equal(harness.calls.some(([kind]) => kind === "select"), false,
    "the only attention session should not reset its draft or question form");
});

test("selected banner offers the correct view without switching panes on an update", () => {
  const harness = attentionHarness([
    session("question", { pendingUserInputs: [{}] }),
    session("permission", { status: "waiting" }),
    session("ready", { ready: true }),
    session("idle"),
  ]);
  for (const [id, expectedMode, expectedButton] of [
    ["question", "conversation", "View question"],
    ["permission", "terminal", "Open terminal"],
    ["ready", "conversation", "View activity"],
  ]) {
    harness.context.selected = id;
    harness.calls.length = 0;
    harness.renderSelectedAttention();
    assert.deepEqual(harness.calls, [], "workspace refresh must never switch panes");
    assert.equal(harness.elements.sessionAttentionBanner.hidden, false);
    assert.equal(harness.elements.attentionOpen.textContent, expectedButton);
    assert.equal(harness.elements.attentionMarkRead.hidden, id !== "ready");
    harness.openSelectedAttention();
    assert.deepEqual(harness.calls[0], ["view", expectedMode]);
  }
  harness.context.selected = "idle";
  harness.elements.attentionReadStatus.textContent = "Old error";
  harness.renderSelectedAttention();
  assert.equal(harness.elements.sessionAttentionBanner.hidden, true);
  assert.equal(harness.elements.attentionReadStatus.textContent, "");
});

test("rows keep selection separate from attention and insert titles as plain text", () => {
  const { renderSessionButton } = attentionHarness();
  const title = '<img src=x onerror="alert(1)">';
  const button = renderSessionButton(session("question", {
    title, status: "running", pendingUserInputs: [{}], scheduled: true, background: true,
  }), "question");
  assert.equal(button.dataset.attention, "waiting");
  assert.equal(button.attributes["aria-current"], "true");
  assert.equal(button.className, "active");
  assert.equal(button.type, "button");
  assert.ok(button.textContent.includes(title));
  assert.ok(button.textContent.includes("Needs input"));
  assert.equal(button.findAll("span").find((node) => node.className === "session-work").textContent,
    "running \u00b7 background \u00b7 scheduled");
  assert.equal(button.findAll("img").length, 0);
  assert.equal(button.children[0].attributes["aria-hidden"], "true");
});

test("mark seen uses the captured session without optimistically clearing shared attention", async () => {
  const harness = attentionHarness([session("ready", { ready: true, unread: true })]);
  harness.context.selected = "ready";
  harness.document.activeElement = harness.elements.attentionMarkRead;
  await harness.markSelectedAttentionRead();
  assert.deepEqual(harness.calls, [
    ["focus", 'button[aria-current="true"]'],
    ["control", { type: "mark-read", sessionId: "ready" }],
  ]);
  assert.equal(harness.context.sessionState.get("ready").ready, true);
  assert.equal(harness.context.sessionState.get("ready").unread, true);
  assert.equal(harness.elements.attentionMarkRead.disabled, false);
  assert.match(harness.elements.attentionReadStatus.textContent, /Waiting for the host/);
  harness.context.sessionState.set("ready", session("ready"));
  harness.renderSelectedAttention();
  assert.equal(harness.elements.sessionAttentionBanner.hidden, true);
});

test("mark seen never dismisses a question, permission request, or ordinary idle session", async () => {
  const harness = attentionHarness([
    session("question", { pendingUserInputs: [{}], unread: true }),
    session("permission", { status: "waiting", unread: true }),
    session("idle"),
  ]);
  for (const id of ["question", "permission", "idle", "removed"]) {
    harness.context.selected = id;
    await harness.markSelectedAttentionRead();
  }
  assert.deepEqual(harness.calls, []);
});

test("failed mark seen remains retryable and in-flight duplicate clicks are ignored", async () => {
  const harness = attentionHarness([session("ready", { ready: true })]);
  harness.context.selected = "ready";
  let finish;
  let requests = 0;
  harness.context.control = () => {
    requests += 1;
    return new Promise((resolve) => { finish = resolve; });
  };
  const pending = harness.markSelectedAttentionRead();
  await harness.markSelectedAttentionRead();
  assert.equal(requests, 1);
  finish(null);
  await pending;
  assert.equal(harness.elements.attentionMarkRead.disabled, false);
  assert.match(harness.elements.attentionReadStatus.textContent, /Could not mark seen/);
  assert.equal(harness.context.sessionState.get("ready").ready, true);
});

test("late mark seen responses cannot contaminate another selection or a new visit", async () => {
  for (const switchBack of [false, true]) {
    const harness = attentionHarness([session("ready", { ready: true })]);
    harness.context.selected = "ready";
    let finish;
    harness.context.control = () => new Promise((resolve) => { finish = resolve; });
    const pending = harness.markSelectedAttentionRead();
    harness.context.selected = switchBack ? "ready" : "other";
    harness.context.selectionGeneration += 1;
    harness.elements.attentionReadStatus.textContent = "";
    harness.elements.attentionMarkRead.disabled = false;
    finish({ ok: false });
    await pending;
    assert.equal(harness.elements.attentionReadStatus.textContent, "");
    assert.equal(harness.elements.attentionMarkRead.disabled, false);
  }
});

test("a host acknowledgement arriving before HTTP completion does not leave stale feedback", async () => {
  const harness = attentionHarness([session("ready", { ready: true })]);
  harness.context.selected = "ready";
  let finish;
  harness.context.control = () => new Promise((resolve) => { finish = resolve; });
  const pending = harness.markSelectedAttentionRead();
  harness.context.sessionState.set("ready", session("ready"));
  harness.renderSelectedAttention();
  finish({ ok: true });
  await pending;
  assert.equal(harness.elements.attentionReadStatus.textContent, "");
});

test("mark-seen feedback cannot leak into a new question or different kind of unseen activity", async () => {
  for (const fields of [
    { status: "waiting" }, { pendingElicitations: [{}] }, { unread: true },
  ]) {
    const harness = attentionHarness([session("ready", { ready: true })]);
    harness.context.selected = "ready";
    harness.renderSelectedAttention();
    let finish;
    harness.context.control = () => new Promise((resolve) => { finish = resolve; });
    const pending = harness.markSelectedAttentionRead();
    harness.context.sessionState.set("ready", session("ready", fields));
    harness.renderSelectedAttention();
    assert.equal(harness.elements.attentionReadStatus.textContent, "");
    finish({ ok: false });
    await pending;
    assert.equal(harness.elements.attentionReadStatus.textContent, "");
  }
});

test("hiding or disabling focused attention controls keeps focus in session navigation", () => {
  const harness = attentionHarness([session("ready", { ready: true })]);
  harness.context.selected = "ready";
  harness.renderSelectedAttention();
  harness.document.activeElement = harness.elements.attentionMarkRead;
  harness.elements.sessionAttentionBanner.append(harness.elements.attentionMarkRead);
  harness.context.sessionState.set("ready", session("ready"));
  harness.renderSelectedAttention();
  assert.deepEqual(harness.calls.pop(), ["focus", 'button[aria-current="true"]']);

  harness.document.activeElement = harness.elements.attentionNext;
  harness.renderAttentionSummary();
  assert.deepEqual(harness.calls.pop(), ["focus", 'button[aria-current="true"]']);

  harness.context.sessionState.set("ready", session("ready", { status: "waiting" }));
  harness.document.activeElement = harness.elements.attentionMarkRead;
  harness.renderSelectedAttention();
  assert.deepEqual(harness.calls.pop(), ["focus", 'button[aria-current="true"]']);

  harness.context.sessions.querySelector = () => null;
  harness.context.sessionState.clear();
  harness.document.activeElement = harness.elements.attentionNext;
  harness.renderAttentionSummary();
  assert.deepEqual(harness.calls.pop(), ["summary-focus"]);
});
