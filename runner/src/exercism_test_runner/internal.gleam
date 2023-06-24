import gap
import gleam/int
import gleam/json.{Json}
import gleam/list
import gleam/result
import gleam/string
import gleam/option.{None, Option, Some}
import gleam/bit_string
import gleam/dynamic.{Dynamic}
import gleam/erlang
import gleam/erlang/atom

pub type Error {
  Unequal(left: Dynamic, right: Dynamic)
  Todo(message: String)
  Panic(message: String)
  Unmatched(value: Dynamic, line: Int)
  UnmatchedCase(value: Dynamic)
  Crashed(error: Dynamic)
}

pub type Suite {
  Suite(name: String, path: String, tests: List(Test))
}

pub type Test {
  Test(
    name: String,
    module_path: String,
    function: fn() -> Result(Nil, Error),
    src: String,
  )
}

pub type TestResult {
  TestResult(test: Test, error: Option(Error), output: String)
}

pub fn extract_function_body(src: String, start: Int, end: Int) -> String {
  src
  |> bit_string.from_string
  |> bit_string.slice(start, end - start)
  |> result.unwrap(<<>>)
  |> bit_string.to_string
  |> result.unwrap("")
  |> string.drop_right(1)
  |> drop_function_header
  |> string.trim
  |> string.split("\n")
  |> list.map(undent)
  |> string.join("\n")
}

fn drop_function_header(src: String) -> String {
  case string.pop_grapheme(src) {
    Ok(#("{", src)) -> src
    Ok(#(_, src)) -> drop_function_header(src)
    Error(_) -> src
  }
}

fn undent(line: String) -> String {
  case string.starts_with(line, "  ") {
    True -> string.drop_left(line, 2)
    False -> line
  }
}

pub fn print_error(error: Error, path: String, test_name: String) -> String {
  case error {
    Unequal(left, right) -> {
      let diff =
        gap.compare_strings(string.inspect(left), string.inspect(right))
        |> gap.to_styled
      string.join(
        [
          path,
          "   test: " <> test_name,
          "  error: left != right",
          "   left: " <> diff.first,
          "  right: " <> diff.second,
        ],
        "\n",
      )
    }
    Todo(message) -> {
      string.join(
        [
          path,
          "   test: " <> test_name,
          "  error: todo",
          "   info: " <> message,
        ],
        "\n",
      )
    }
    Panic(message) -> {
      string.join(
        [
          path,
          "   test: " <> test_name,
          "  error: panic",
          "   info: " <> message,
        ],
        "\n",
      )
    }
    Unmatched(value, line) -> {
      string.join(
        [
          path <> ":" <> int.to_string(line),
          "   test: " <> test_name,
          "  error: Pattern match failed",
          "  value: " <> string.inspect(value),
        ],
        "\n",
      )
    }
    UnmatchedCase(value) -> {
      string.join(
        [
          path,
          "   test: " <> test_name,
          "  error: Pattern match failed",
          "  value: " <> string.inspect(value),
        ],
        "\n",
      )
    }
    Crashed(error) -> {
      string.join(
        [
          path,
          "   test: " <> test_name,
          "  error: Program crashed",
          "  cause: " <> string.inspect(error),
        ],
        "\n",
      )
    }
  }
}

pub fn print_summary(results: List(TestResult)) -> #(Bool, String) {
  let total =
    results
    |> list.length
    |> int.to_string
  let failed =
    results
    |> list.filter(fn(result) { result.error != None })
    |> list.length
    |> int.to_string
  let message = "Ran " <> total <> " tests, " <> failed <> " failed"
  #(failed == "0", message)
}

pub fn run_test_function(function: fn() -> a) -> Result(Nil, Error) {
  function
  |> erlang.rescue
  |> result.map_error(convert_error)
  |> result.replace(Nil)
}

fn convert_error(error: erlang.Crash) -> Error {
  case error {
    erlang.Exited(error) -> Crashed(error)
    erlang.Thrown(error) -> Crashed(error)
    erlang.Errored(error) -> {
      let decoders = [
        decode_unequal_error,
        decode_pattern_match_failed_error,
        decode_case_clause_error,
        decode_todo_error,
        decode_panic_error,
      ]
      error
      |> dynamic.any(decoders)
      |> result.unwrap(Crashed(error))
    }
  }
}

fn decode_pattern_match_failed_error(
  error: Dynamic,
) -> Result(Error, dynamic.DecodeErrors) {
  let decoder =
    dynamic.decode3(
      fn(_, value, line) { Unmatched(value, line) },
      dynamic.field(
        atom.create_from_string("gleam_error"),
        decode_tag("Assertion pattern match failed", _),
      ),
      dynamic.field(atom.create_from_string("value"), Ok),
      dynamic.field(atom.create_from_string("line"), dynamic.int),
    )
  decoder(error)
}

fn decode_todo_error(error: Dynamic) -> Result(Error, dynamic.DecodeErrors) {
  let decoder =
    dynamic.decode2(
      fn(_, message) { Todo(message) },
      dynamic.field(
        atom.create_from_string("gleam_error"),
        decode_tag(atom.create_from_string("todo"), _),
      ),
      dynamic.field(atom.create_from_string("message"), dynamic.string),
    )
  decoder(error)
}

fn decode_panic_error(error: Dynamic) -> Result(Error, dynamic.DecodeErrors) {
  let decoder =
    dynamic.decode2(
      fn(_, message) { Panic(message) },
      dynamic.field(
        atom.create_from_string("gleam_error"),
        decode_tag(atom.create_from_string("panic"), _),
      ),
      dynamic.field(atom.create_from_string("message"), dynamic.string),
    )
  decoder(error)
}

fn decode_case_clause_error(
  error: Dynamic,
) -> Result(Error, dynamic.DecodeErrors) {
  let decoder =
    dynamic.decode2(
      fn(_, value) { UnmatchedCase(value) },
      dynamic.element(0, decode_tag(atom.create_from_string("case_clause"), _)),
      dynamic.element(1, Ok),
    )
  decoder(error)
}

fn decode_unequal_error(error: Dynamic) -> Result(Error, dynamic.DecodeErrors) {
  let tag = atom.create_from_string("unequal")
  let decoder =
    dynamic.decode3(
      fn(_, a, b) { Unequal(a, b) },
      dynamic.element(0, decode_tag(tag, _)),
      dynamic.element(1, Ok),
      dynamic.element(2, Ok),
    )
  decoder(error)
}

fn decode_tag(tag: anything, data: Dynamic) -> Result(Nil, dynamic.DecodeErrors) {
  case dynamic.from(tag) == data {
    True -> Ok(Nil)
    False -> Error([dynamic.DecodeError("Tag", dynamic.classify(data), [])])
  }
}

pub type ProcessDictionaryKey {
  ExecismTestRunnerUserOutput
}

external fn process_dictionary_set(ProcessDictionaryKey, String) -> Dynamic =
  "erlang" "put"

external fn process_dictionary_get(ProcessDictionaryKey) -> Dynamic =
  "erlang" "get"

/// Append a string to the output store in the process dictionary.
/// In future it may be preferable to use a global actor or similar so we can
/// merge in any writing to stdout. Writing to stderr is not possible to
/// capture.
pub fn append_output(value: String) -> Nil {
  ExecismTestRunnerUserOutput
  |> process_dictionary_get
  |> dynamic.string()
  |> result.unwrap("")
  |> string.append(value)
  |> string.append("\n")
  |> process_dictionary_set(ExecismTestRunnerUserOutput, _)
  Nil
}

pub fn clear_output() -> Nil {
  process_dictionary_set(ExecismTestRunnerUserOutput, "")
  Nil
}

pub fn get_output() -> String {
  ExecismTestRunnerUserOutput
  |> process_dictionary_get
  |> dynamic.string()
  |> result.unwrap("")
}

pub fn run_test(test: Test) -> TestResult {
  clear_output()
  let error = case test.function() {
    Ok(_) -> None
    Error(error) -> Some(error)
  }
  TestResult(test: test, error: error, output: get_output())
}

pub fn results_to_json(results: List(TestResult)) -> String {
  let failed = list.any(results, fn(test) { test.error != None })
  let status = case failed {
    True -> "fail"
    False -> "pass"
  }
  json.object([
    #("version", json.int(2)),
    #("status", json.string(status)),
    #("tests", json.array(results, test_result_json)),
  ])
  |> json.to_string
}

fn test_result_json(result: TestResult) -> Json {
  let fields = case result.error {
    Some(error) -> {
      let error = print_error(error, result.test.module_path, result.test.name)
      [#("status", json.string("fail")), #("message", json.string(error))]
    }
    None -> [#("status", json.string("pass"))]
  }
  let fields = case truncate(result.output) {
    "" -> fields
    output -> [#("output", json.string(output)), ..fields]
  }
  let fields = [
    #("name", json.string(result.test.name)),
    #("test_code", json.string(result.test.src)),
    ..fields
  ]
  json.object(fields)
}

fn truncate(output: String) -> String {
  case string.length(output) > 500 {
    True ->
      output
      |> string.slice(0, 448)
      |> string.append("...\n\n")
      |> string.append("Output was truncated. Please limit to 500 chars")
    False -> output
  }
}