# Documentation site

The published manual is the Markdown in `site/docs/`. [zdoc](https://github.com/chy3xyz/zdoc) 0.16.2 turns that folder into HTML. Longer notes in `docs/` are not copied onto the site.

```bash
bash scripts/build_docs.sh
```

Output is `site/public/`. The link prefix is `/mem3/`, for <https://chy3xyz.github.io/mem3/>. Pass `/` as the second argument to serve the folder at a domain root.
