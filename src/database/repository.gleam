import gleam/time/calendar
import gleam/json
import database/sql
import gleam/list
import gleam/result
import gleam/time/timestamp.{type Timestamp}
import pog

pub type Repository {
  Repository(github_id: Int, owner: String, name: String, created_at: Timestamp)
}

pub fn list(db: pog.Connection) {
  use pog.Returned(_num, repos) <- result.try(sql.list_repositories(db))
  Ok(list.map(repos, map_repository))
}

fn map_repository(row: sql.ListRepositoriesRow) -> Repository {
  Repository(
    github_id: row.github_id,
    owner: row.owner,
    name: row.name,
    created_at: row.created_at,
  )
}

pub fn to_json(repository: Repository) -> json.Json {
  json.object([
    #("github_id", json.int(repository.github_id)),
    #("owner", json.string(repository.owner)),
    #("name", json.string(repository.name)),
    #("created_at", json.string(timestamp.to_rfc3339(repository.created_at, calendar.utc_offset)))
  ])
}