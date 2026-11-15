/* Shared menu for the Fabric planning site.
   Add a tool by appending one object below, then start the new file
   (also in docs/) with:
     <link rel="stylesheet" href="site.css" />
     <body data-page="THE_ID">
     <script src="nav.js"></script>
   href is relative to docs/. "./" is this site's home page. */
(function () {
  var pages = [
    { id: "cu", href: "./", label: "AI Capacity planner" },
    { id: "workloads", href: "./workloads.html", label: "Workload planner" }
  ];

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
