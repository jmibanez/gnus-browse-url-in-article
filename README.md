# gnus-browse-url-in-article: Smartly open URLs in Gnus articles

Do you ever open an HTML article full of links and want a way to quickly browse to a particular URL in that article? Do you maintain GitHub projects and want to quickly jump to the relevant pull request when reading an email notification from GitHub?

`gnus-browse-url-in-article` allows you to more smartly browse to the "best" URL in an article. For instance, if you
bind `C-<tab>` in gnus-summary-mode-map:

```elisp
  (bind-keys :map gnus-summary-mode-map ("C-<tab>" . gnus-browse-url-in-article))
```

then with point on an article in the summary view and, hitting `C-<tab>`, by default `gnus-browse-url-in-article` will `completing-read` all link texts for all URLs in that article; selecting a link text will launch the associated URL on your configured browser (via `browse-url`) for that link text.

## Built-in Handlers

Out of the box, `gnus-browse-url-in-article` handles the following article types:

  * GitHub Pull Request notifications
  * LinkedIn Job Alert notifications
  * Ars Technica newsletters

Additionally, if the article has an HTML MIME part, and the HTML `<head>` contains metadata about its canonical URL `gnus-browse-url-in-article` will fallback to browsing that canonical URL.

### GitHub Pull Requests

When viewing a GitHub Pull Request notification email (new comment, new PR, etc.), `gnus-browse-url-in-article` will browse to the URL of the relevant GitHub PR.

### LinkedIn Job Alerts

For LinkedIn Job Alerts, each job posting will be collected and displayed as "Company - Title"; all other URLs will be omitted.

### Ars Technica newsletters

Links to article titles in the newsletter will be collected and displayed.

## Adding Handlers

You can create your own handlers, which you can then add to the `gnus-browse-url-in-article` handler chain. The simplest way to create a handler is to create two functions and use `gnus-browse-url-in-article-make-handler` on them. The first function you would need to write is a predicate that returns `t` if your handler should handle the article; the second function should then return an alist `(description . url)` of all the URLs in the article.

For most simple cases, this package provides `gnus-browse-url-in-article-if-from` to create predicates that check the `From:` header matching against a given regexp.

```elisp
  (defun get-article-urls-from-foo ()
     ;; implement your article URL fetcher here
     ...)

  (gnus-browse-url-in-article-make-handler
     (gnus-browse-url-in-article-if-from "somebody@example.com")
     #'get-article-urls-from-foo)
```

For more involved cases, subclass the EIEIO class `gnus-browse-url-in-article-handler` and implement two methods:

  * `gnus-browse-url-in-article-handler-matches-p` for the predicate,
  * `gnus-browse-url-in-article-handler-get-urls` to return the alist of `(description . url)` of URLs in the article.
  
