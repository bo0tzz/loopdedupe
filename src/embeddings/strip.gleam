//// Strip GitHub issue template boilerplate from a body, keeping the
//// reporter's prose.
////
//// immich's issue template has drifted over time but the noisy bits are
//// stable in shape: '<!-- -->' comment instructions, '### ...' section
//// headers, fenced code blocks for env dumps, '- [ ] / - [X]' checkbox
//// lines for platform selection, and '_No response_' placeholders for
//// empty sections. Removing those gives us close to just the user's words,
//// which is what the embedding model needs to make the title+body combo
//// discriminative instead of dominated by the template's near-identical
//// scaffolding.

import gleam/regexp.{type Regexp}
import gleam/string

pub fn strip_template(text: String) -> String {
  text
  |> replace(html_comments(), "")
  |> replace(fenced_code(), "")
  |> replace(checkbox_lines(), "")
  |> replace(no_response_placeholder(), "")
  |> replace(section_headers(), "")
  |> replace(trailing_spaces(), "\n")
  |> replace(blank_runs(), "\n\n")
  |> string.trim
}

fn replace(text: String, with re: Regexp, by replacement: String) -> String {
  regexp.replace(re, text, replacement)
}

fn html_comments() -> Regexp {
  let assert Ok(re) =
    regexp.compile("<!--[\\s\\S]*?-->", regexp.Options(False, False))
  re
}

fn fenced_code() -> Regexp {
  let assert Ok(re) =
    regexp.compile("```[\\s\\S]*?```", regexp.Options(False, False))
  re
}

fn checkbox_lines() -> Regexp {
  let assert Ok(re) =
    regexp.compile(
      "^\\s*-\\s*\\[[\\sxX]\\]\\s*.*$",
      regexp.Options(False, True),
    )
  re
}

fn no_response_placeholder() -> Regexp {
  let assert Ok(re) =
    regexp.compile("_no response_", regexp.Options(True, False))
  re
}

fn section_headers() -> Regexp {
  let assert Ok(re) =
    regexp.compile("^#{1,6}\\s+.*$", regexp.Options(False, True))
  re
}

fn trailing_spaces() -> Regexp {
  let assert Ok(re) =
    regexp.compile("[ \\t]+\\n", regexp.Options(False, False))
  re
}

fn blank_runs() -> Regexp {
  let assert Ok(re) =
    regexp.compile("\\n\\s*\\n\\s*\\n+", regexp.Options(False, False))
  re
}
