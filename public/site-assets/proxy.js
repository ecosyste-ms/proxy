document.documentElement.classList.add("js");

document.querySelectorAll('[data-bs-toggle="collapse"]').forEach((toggle) => {
  const target = document.getElementById(toggle.getAttribute("aria-controls"));
  if (!target) return;
  toggle.addEventListener("click", (event) => {
    event.preventDefault();
    const expanded = target.classList.toggle("show");
    toggle.setAttribute("aria-expanded", String(expanded));
  });
});

const snippets = Array.from(document.querySelectorAll("[data-cooldown-config]"), (code) => ({
  code,
  original: code.textContent,
}));
const cooldownOptions = document.querySelectorAll('input[name="cooldown"]');

document.querySelectorAll(".install-item").forEach((item) => {
  if (!item.querySelector("[data-cooldown-config]")) return;
  const badge = document.createElement("span");
  badge.className = "cooldown-available";
  badge.textContent = "Cooldown available";
  item.querySelector("summary").appendChild(badge);
});

function updateCooldown(profile) {
  const base = "https://proxy.ecosyste.ms";
  const selected = profile ? `${base}/cooldown/${profile}` : base;
  document.documentElement.classList.toggle("has-cooldown", Boolean(profile));
  snippets.forEach(({ code, original }) => {
    code.textContent = original.replaceAll(base, selected);
    if (profile && code.dataset.cooldownExtra) {
      code.textContent += `\n${code.dataset.cooldownExtra}`;
    }
  });
  document.querySelectorAll("[data-copy]").forEach((button) => { button.textContent = "Copy"; });
  document.getElementById("copy-status").textContent = profile
    ? `Configurations updated to a ${parseInt(profile, 10)}-day release cooldown.`
    : "Configurations updated with no release cooldown.";
}

cooldownOptions.forEach((option) => {
  option.addEventListener("change", () => { updateCooldown(option.value); });
});
updateCooldown(document.querySelector('input[name="cooldown"]:checked').value);

document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const code = document.getElementById(button.dataset.copy);
    const status = document.getElementById("copy-status");
    const text = code.textContent;
    try {
      await navigator.clipboard.writeText(text);
      if (code.textContent !== text) return;
      button.textContent = "Copied";
      status.textContent = `${button.getAttribute("aria-label")} copied to clipboard.`;
      setTimeout(() => { button.textContent = "Copy"; }, 2000);
    } catch {
      status.textContent = "Select and copy the configuration text.";
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(code);
      selection.removeAllRanges();
      selection.addRange(range);
    }
  });
});
