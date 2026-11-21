# OpenPics (the user's earlier image-source app) — sources to study

The user (repo owner) built OpenPics, an iOS app that browsed images from many remote sources:
https://github.com/pj4533/OpenPics (shipped code on branch `latest_shipped`; an unfinished Swift rewrite on `master`).
Local clones (read freely, they are the user's own code): 
- shipped: /private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/imageapi/openpics-shipped/OpenPics/Classes/Providers/
- rewrite: /private/tmp/claude-501/-Users-pj4533-Developer-Liminal/b8f97122-abd8-4cd6-b289-17658fba4b13/scratchpad/imageapi/openpics/OpenPics/APIs/

Providers it shipped (circa 2013-2016; endpoints may have changed, re-check them):
- Library of Congress: loc.gov/pictures/search?q=..&fo=json&c=100&sp=page, collection sets via `co=<code>`, hi-res via the item's
  `links.resource` + `?fo=json` → `resource.largest / larger / large` (with *_s sizes; it skipped files over 12 MB). The modern API is
  loc.gov/{photos,pictures}/?fo=json (check).
- NYPL Digital Collections (token; images.nypl.org/index.php?id=..&t=w; "NYPL allows hi rez now" per the TODO).
- DPLA (api key; aggregates CONTENTdm hubs, used 2048 px CONTENTdm scaling URLs).
- Europeana (api key; qf=image; Wellcome, Leodis, Kirklees/Bamforth, Picture Sheffield links).
- Trove (National Library of Australia, key; zone=picture; NGA/AWM/NAA image hosts).
- California Digital Library / Calisphere (content.cdlib.org, imgzoom JP2 converter).
- Flickr Commons, plus Boston Public Library and Cambridge Historical Society Flickr accounts (Flickr key; url_b/url_o extras).
- LIFE Magazine photo archive (was hosted by Google Images; probably gone).
- Reddit image subs: HistoryPorn, TheWayWeWere, OldSchoolCool (rights unclear; likely exclude).
- "Popular" (a backend of favourited images) and local Favorites.

Use these as a starting list alongside the modern candidates: verify which still work, their current endpoints, keys, resolution and
rights, and prefer what fits Liminal's vibe and licensing rules.
