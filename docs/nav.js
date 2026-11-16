/* Shared menu for the Fabric planning site.
   Add a tool by appending one object below.
   For a clean URL on GitHub Pages, put the page at docs/<id>/index.html
   (served as /jujutsu/<id>/) and link site.css + nav.js with ../ .
   Start the file with:
     <link rel="stylesheet" href="../site.css" />
     <body data-page="THE_ID">
     <script src="../nav.js"></script>
   The home page stays at docs/index.html. */
(function () {
  var base = "/jujutsu/";
  var pages = [
    { id: "cu", href: base, label: "AI Capacity planner" },
    { id: "workloads", href: base + "workloads/", label: "Workload planner" }
  ];

  var current = document.body.getAttribute("data-page") || "";
  var header = document.createElement("header");
  header.className = "site-header";
  var bar = document.createElement("div");
  bar.className = "site-bar";
  var brand = document.createElement("a");
  brand.className = "site-brand";
  brand.href = base;
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