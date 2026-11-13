/* Shared menu for the Fabric planning site.
   Add a tool by appending one object below, then start the new file
   (also in docs/) with:
     <body data-page="THE_ID">
     <script src="nav.js"></script>
   href is relative to docs/. "./" is this site's home page. */
(function () {
  var pages = [
    { id: "cu", href: "./", label: "Capacity planner" }
  ];

  var style = document.createElement("style");
  style.textContent = [
    ".site-header { position: sticky; top: 0; z-index: 20; background: var(--paper, #f3efe6); border-bottom: 1px solid var(--line, #ddd4c4); }",
    ".site-bar { max-width: 64rem; margin: 0 auto; padding: 0.7rem 1rem; display: flex; flex-wrap: wrap; align-items: center; gap: 0.45rem 0.85rem; }",
    ".site-brand { margin-right: auto; font-family: var(--serif, Georgia, serif); font-size: 1.15rem; font-weight: 600; color: var(--ink, #1a2330); text-decoration: none; line-height: 1.2; }",
    ".site-nav { display: flex; flex-wrap: wrap; gap: 0.35rem; }",
    ".site-nav a { text-decoration: none; color: var(--ink, #1a2330); font-size: 0.88rem; font-weight: 650; line-height: 1.2; padding: 0.4rem 0.75rem; border-radius: 999px; border: 1px solid transparent; }",
    ".site-nav a:hover { background: var(--sheet, #fbf8f2); border-color: var(--line, #ddd4c4); }",
    ".site-nav a[aria-current='page'] { background: var(--accent, #0f6e78); color: var(--accent-ink, #f4fffe); border-color: var(--accent, #0f6e78); }",
    ".site-nav a[aria-current='page']:hover { background: var(--accent, #0f6e78); }"
  ].join("\n");
  document.head.appendChild(style);

  var current = document.body.getAttribute("data-page") || "";
  var header = document.createElement("header");
  header.className = "site-header";
  var bar = document.createElement("div");
  bar.className = "site-bar";
  var brand = document.createElement("a");
  brand.className = "site-brand";
  brand.href = "./";
  brand.textContent = "Fabric planning";
  var nav = document.createElement("nav");
  nav.className = "site-nav";
  nav.setAttribute("aria-label", "Tools");
  pages.forEach(function (page) {
    var link = document.createElement("a");
    link.href = page.href;
    link.textContent = page.label;
    if (page.id === current) link.setAttribute("aria-current", "page");
    nav.appendChild(link);
  });
  bar.appendChild(brand);
  bar.appendChild(nav);
  header.appendChild(bar);
  document.body.insertBefore(header, document.body.firstChild);
})();
