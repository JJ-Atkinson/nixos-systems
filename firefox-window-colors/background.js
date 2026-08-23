// Titlebar colors from Ghostty desktop entries (home.nix)
const COLORS = [
  { frame: "#35de8f", text: "#000000" }, // green
  { frame: "#A0CFD3", text: "#000000" }, // blue
  { frame: "#9a7aa0", text: "#ffffff" }, // purple
  { frame: "#d1d133", text: "#000000" }, // yellow
  { frame: "#E89B5C", text: "#000000" }, // orange
  { frame: "#E88B8B", text: "#000000" }, // red
  { frame: "#8BB8E8", text: "#000000" }, // sky
  { frame: "#E8A0C8", text: "#000000" }, // pink
];

let next = 0;

function themeFor(color) {
  return {
    colors: {
      frame: color.frame,
      frame_inactive: color.frame,
      tab_background_text: color.text,
      toolbar_text: color.text,
      bookmark_text: color.text,
    },
  };
}

function colorWindow(windowId) {
  const color = COLORS[next % COLORS.length];
  next += 1;
  browser.theme.update(windowId, themeFor(color));
}

browser.windows.onCreated.addListener((win) => {
  if (win.type !== "normal") return;
  colorWindow(win.id);
});

browser.windows.getAll({ windowTypes: ["normal"] }).then((wins) => {
  for (const win of wins) {
    colorWindow(win.id);
  }
});
