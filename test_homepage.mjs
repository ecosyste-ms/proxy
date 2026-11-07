import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const html = readFileSync(new URL("public/index.html", import.meta.url), "utf8");
const script = readFileSync(new URL("public/site-assets/proxy.js", import.meta.url), "utf8");
const base = "https://proxy.ecosyste.ms";
const supported = ["npm", "pip", "uv", "bundler", "go", "cargo", "composer", "hex", "pub", "maven", "nuget", "conda"];
const decode = (text) => text.replace(/&(#\d+|amp|lt|gt|quot|apos);/g, (_, entity) => entity.startsWith("#")
  ? String.fromCodePoint(Number(entity.slice(1))) : ({ amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" })[entity]);

function page() {
  const codes = new Map(Array.from(html.matchAll(/<code id="([^"]+)"([^>]*)>([\s\S]*?)<\/code>/g), ([, id, attributes, text]) => [id, {
    textContent: decode(text),
    original: decode(text),
    supported: attributes.includes("data-cooldown-config"),
    dataset: { cooldownExtra: decode(attributes.match(/data-cooldown-extra="([^"]*)"/)?.[1] || "") },
  }]));
  const buttons = new Map(Array.from(html.matchAll(/<button[^>]*data-copy="([^"]+)"[^>]*aria-label="([^"]+)"/g), ([, id, label]) => [id, {
    textContent: "Copy", dataset: { copy: id },
    addEventListener(event, callback) { this[event] = callback; },
    getAttribute(name) { return name === "aria-label" ? label : null; },
  }]));
  const options = Array.from(html.matchAll(/<input[^>]*name="cooldown"[^>]*value="([^"]*)"/g), ([, value]) => ({
    value, addEventListener(event, callback) { this[event] = callback; },
  }));
  const items = Array.from(html.matchAll(/<details class="install-item"[^>]*>([\s\S]*?)<\/details>/g), ([, content]) => ({
    badges: [],
    querySelector(selector) {
      if (selector === "[data-cooldown-config]") return content.includes("data-cooldown-config");
      if (selector === "summary") return { appendChild: (badge) => this.badges.push(badge) };
      throw new Error(`Unexpected item selector: ${selector}`);
    },
  }));
  const status = { textContent: "" };
  const classes = new Set();
  const clipboard = [];
  const document = {
    documentElement: { classList: { add: (name) => classes.add(name), toggle: (name, enabled) => enabled ? classes.add(name) : classes.delete(name) } },
    querySelectorAll(selector) {
      if (selector === '[data-bs-toggle="collapse"]') return [];
      if (selector === "[data-cooldown-config]") return Array.from(codes.values()).filter((code) => code.supported);
      if (selector === "[data-copy]") return Array.from(buttons.values());
      if (selector === 'input[name="cooldown"]') return options;
      if (selector === ".install-item") return items;
      throw new Error(`Unexpected selector: ${selector}`);
    },
    querySelector: () => options[0],
    getElementById: (id) => id === "copy-status" ? status : codes.get(id),
    createElement: () => ({}),
  };
  const navigator = { clipboard: { writeText: async (text) => { clipboard.push(text); } } };
  vm.runInNewContext(script, { document, navigator, setTimeout() {} });
  return {
    codes, buttons, items, status, classes, clipboard, navigator,
    select(profile) { options.find((option) => option.value === profile).change(); },
  };
}

test("all cooldown choices update the actual configs and their copy actions", async () => {
  const p = page();
  assert.equal(p.items.length, 24);
  assert.deepEqual(Array.from(p.codes).filter(([, code]) => code.supported).map(([id]) => id).sort(), supported.map((name) => `${name}-config`).sort());
  for (const profile of ["3d", "1d", "7d", "", "3d"]) {
    p.select(profile);
    for (const name of supported) {
      const id = `${name}-config`;
      const code = p.codes.get(id);
      const urls = code.textContent.match(/https:\/\/proxy\.ecosyste\.ms[^\s"<,)]+/g);
      assert.ok(urls.length > 0, id);
      for (const url of urls) {
        assert.equal(url.startsWith(`${base}/cooldown/${profile}/`), Boolean(profile), `${id}: ${url}`);
        assert.ok(!url.includes("/cooldown/3d/cooldown/"), url);
      }
      await p.buttons.get(id).click();
      assert.equal(p.clipboard.at(-1), code.textContent, id);
      if (!profile) assert.equal(code.textContent, code.original, id);
    }
  }
});

test("cache-only registries keep their URLs and remain listed", () => {
  const p = page();
  p.select("7d");
  for (const [id, code] of p.codes) {
    if (!code.supported) assert.equal(code.textContent, code.original, id);
  }
  assert.ok(p.classes.has("has-cooldown"));
  p.select("");
  assert.ok(!p.classes.has("has-cooldown"));
});

test("only supported package managers show cooldown availability", () => {
  const p = page();
  for (const profile of ["", "3d", "7d", "1d", ""]) {
    p.select(profile);
    for (const item of p.items) {
      const available = item.querySelector("[data-cooldown-config]");
      assert.equal(item.badges.length, available ? 1 : 0);
      if (available) {
        assert.equal(item.badges[0].textContent, "Cooldown available");
        assert.equal(item.badges[0].className, "cooldown-available");
      }
    }
  }
});

test("Hex cooldown disables only registry signature verification", () => {
  const p = page();
  for (const profile of ["1d", "3d", "7d"]) {
    p.select(profile);
    assert.match(p.codes.get("hex-config").textContent, /\nexport HEX_UNSAFE_REGISTRY=1$/);
    assert.doesNotMatch(p.codes.get("hex-config").textContent, /HEX_NO_VERIFY_REPO_ORIGIN/);
  }
  p.select("");
  assert.equal(p.codes.get("hex-config").textContent, p.codes.get("hex-config").original);
});

test("changing profiles clears stale copy feedback", async () => {
  const p = page();
  const button = p.buttons.get("npm-config");
  await button.click();
  assert.equal(button.textContent, "Copied");
  p.select("7d");
  assert.equal(button.textContent, "Copy");
  assert.match(p.status.textContent, /7-day/);
  let resolveCopy;
  p.navigator.clipboard.writeText = () => new Promise((resolve) => { resolveCopy = resolve; });
  const copying = button.click();
  p.select("1d");
  resolveCopy();
  await copying;
  assert.equal(button.textContent, "Copy");
  assert.match(p.status.textContent, /1-day/);
});

test("asset URLs match the current file contents", () => {
  for (const extension of ["css", "js"]) {
    const content = readFileSync(new URL(`public/site-assets/proxy.${extension}`, import.meta.url));
    const hash = createHash("sha256").update(content).digest("hex").slice(0, 12);
    assert.ok(html.includes(`/site-assets/proxy.${extension}?hash=${hash}`));
  }
});

test("social previews use the page metadata and a valid branded image", () => {
  const meta = new Map(Array.from(html.matchAll(/<meta (?:name|property)="([^"]+)" content="([^"]*)">/g), ([, key, value]) => [key, value]));
  const title = html.match(/<title>(.*?)<\/title>/)[1];
  assert.equal(meta.get("og:type"), "website");
  assert.equal(meta.get("og:site_name"), "ecosyste.ms");
  assert.equal(meta.get("og:url"), `${base}/`);
  assert.equal(meta.get("twitter:card"), "summary_large_image");
  for (const prefix of ["og", "twitter"]) {
    assert.equal(meta.get(`${prefix}:title`), title);
    assert.equal(meta.get(`${prefix}:description`), meta.get("description"));
    assert.equal(meta.get(`${prefix}:image`), `${base}/site-assets/social-share.png`);
    assert.ok(meta.get(`${prefix}:image:alt`));
  }
  const image = readFileSync(new URL("public/site-assets/social-share.png", import.meta.url));
  assert.equal(image.subarray(1, 4).toString(), "PNG");
  assert.equal(meta.get("og:image:type"), "image/png");
  assert.equal(Number(meta.get("og:image:width")), image.readUInt32BE(16));
  assert.equal(Number(meta.get("og:image:height")), image.readUInt32BE(20));
});
