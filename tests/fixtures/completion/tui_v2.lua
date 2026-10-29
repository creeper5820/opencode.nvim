-- OpenCode V2 TUI completion/submit expectations used by the 07B tests.
--
-- Values below are the externally visible behaviour of the OpenCode 2.0.31
-- TUI prompt autocomplete and prompt submit paths:
--
--   * `@` opens the reference completion list (files, agents, skills).
--   * `/` opens command completion only at prompt index 0.
--   * command tokens reject whitespace and a second slash.
--   * mention tokens reject whitespace; `@` must be at the start or after
--     whitespace.
--   * files are found with limit 20 and inserted as `@<relative path> `;
--     directories continue with `@<relative path>/`.
--   * `#start[-end]` line ranges are stripped from the query and appended to
--     the inserted file name.
--   * agents are filtered to `hidden ~= true` and `mode ~= "primary"`.
--   * agents, skills and files are submitted as structured prompt parts, not
--     by parsing their display text.
--
-- The fixture is deliberately data-only so tests can compare source behaviour
-- against it without loading a TUI.

return {
  version = "2.0.31",
  triggers = {
    command = "/",
    mention = "@",
  },
  command = {
    only_at_prompt_start = true,
    reject_whitespace = true,
    reject_second_slash = true,
    insertion = "/%s ",
    submit = {
      kind = "command",
      name = "%s",
      arguments = "%s",
    },
  },
  mention = {
    before_must_be_start_or_whitespace = true,
    reject_whitespace = true,
    file_find_limit = 20,
    file_insertion = "@%s ",
    directory_insertion = "@%s/",
    line_range_suffix = "#%d",
    line_range_end_suffix = "#%d-%d",
  },
  agent = {
    filter = {
      hidden = false,
      mode_not = "primary",
    },
    insertion = "@%s ",
    attachment = {
      name = "%s",
      mention = {
        start = 0,
        ["end"] = 0,
        text = "@%s",
      },
    },
  },
  skill = {
    insertion = "@%s ",
    attachment = {
      id = "%s",
      mention = {
        start = 0,
        ["end"] = 0,
        text = "@%s",
      },
    },
  },
  file = {
    attachment = {
      uri = "file://<absolute path>",
      name = "<relative path>",
      mention = {
        start = 0,
        ["end"] = 0,
        text = "@<relative path>",
      },
    },
  },
  unsupported = {
    reference = "project reference completion is not implemented by 07B",
  },
}
