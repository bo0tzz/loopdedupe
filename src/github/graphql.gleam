import config
import github/types
import gleam/dynamic/decode
import gleam/httpc
import gleam/json
import gleam/option
import squall

pub fn new_client() {
  let token = config.get_env(config.GithubToken)
  squall.new_with_auth("https://api.github.com/graphql", token)
}

pub fn list_items(client: squall.Client, cursor: option.Option(String)) {
  let query =
    "
    query ListItems($cursor: String) {
      repository(owner: \"bo0tzz\", name: \"loopdedupe-test-issues\") {
        issues(first: 10, after: $cursor) {
          nodes {
              databaseId
              number
              title
              body
              state
              stateReason
              url
          }
          pageInfo {
              endCursor
          }
        }
      }
    }
  "
  let assert Ok(request) =
    squall.prepare_request(
      client,
      query,
      json.object([#("cursor", json.nullable(cursor, json.string))]),
    )

  let assert Ok(response) = httpc.send(request)

  squall.parse_response(response.body, list_items_response_decoder())
}

pub type ListItemsResponse {
  ListItemsResponse(items: List(types.Issue), page_info: PageInfo)
}

fn list_items_response_decoder() -> decode.Decoder(ListItemsResponse) {
  let decoder = {
    use items <- decode.field("nodes", decode.list(types.issue_decoder()))
    use page_info <- decode.field("pageInfo", page_info_decoder())
    decode.success(ListItemsResponse(items:, page_info:))
  }

  decode.at(["repository", "issues"], decoder)
}

pub type PageInfo {
  PageInfo(cursor: option.Option(String))
}

fn page_info_decoder() -> decode.Decoder(PageInfo) {
  use cursor <- decode.field("endCursor", decode.optional(decode.string))
  decode.success(PageInfo(cursor:))
}
