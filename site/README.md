# mem3 documentation site

Static pages for mem3, built with [zdoc](https://github.com/chy3xyz/zdoc) 0.16.2.
The pages you edit are Markdown under `site/docs/`. The build copies the
repository's English docs, the MVP spec, the constitution, `dev.md`, and the
GHW paper into that tree before zdoc runs. There is no Node.js and no config
file beyond `site/docs/.zdoc-theme/site.yaml`.

```bash
bash scripts/build_docs.sh
```

Output is `site/public/`. The default URL prefix is `/mem3/`, so links work on
`https://chy3xyz.github.io/mem3/`. Pass a second argument of `/` to build for
a domain root.

The Chinese manuscript `docs/属性数学_出版版.md` and `docs/releases/` are not
copied. The release notes' performance table does not match the current bench.
