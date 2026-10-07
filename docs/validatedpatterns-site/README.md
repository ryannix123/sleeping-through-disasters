# validatedpatterns.io listing (staged)

These files are the pattern's page for the Validated Patterns website, staged
here so they are reviewed alongside the pattern. They are copied into a fork
of [validatedpatterns/docs](https://github.com/validatedpatterns/docs) at the
same paths and submitted as a pull request **after** the community's
technical and architecture reviews:

| Here | In validatedpatterns/docs |
|---|---|
| `content/patterns/sleeping-through-disasters/_index.adoc` | same path |
| `content/patterns/sleeping-through-disasters/getting-started.adoc` | same path |
| `static/images/logos/sleeping-through-disasters.png` | same path |
| `static/images/sleeping-through-disasters/architecture-diagram.png` | same path |

```bash
# from a clone of your fork of validatedpatterns/docs
cp -r ../sleeping-through-disasters/docs/validatedpatterns-site/content .
cp -r ../sleeping-through-disasters/docs/validatedpatterns-site/static .
make serve        # preview at http://localhost:4000 before opening the PR
```

Before submitting, update `links:` in `_index.adoc` if the repository moves
to the `validatedpatterns-sandbox` organization, and refresh `date:`.
