-- Workaround candidate for the client's nil-function error when callbacks are
-- omitted. These functions deliberately do not inspect the request, log, change
-- state, update UI, or invoke application code. Logic owns all response work.
return {
    completion = function(_request) end,
    progress = function(_request) end,
}
