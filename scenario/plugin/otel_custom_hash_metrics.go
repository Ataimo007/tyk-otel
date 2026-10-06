// Tyk Go plugin (post_key_auth): exposes the authenticated key's hash as the context variable
// "hashed_api_key", so a gateway custom metric can use it as a dimension:
//   { "source": "context", "key": "hashed_api_key", "label": "key_hash" }
//
// Requirements on the API definition: "enable_context_vars": true, and this function registered
// as a post_key_auth Go plugin (it needs the authenticated session, which exists only after auth).
package main

import (
	"net/http"

	"github.com/TykTechnologies/tyk/ctx"
)

// HashAPIKey adds the session's key hash (the same hash the Dashboard shows for the key) to the
// request's context variables. It never fails the request.
func HashAPIKey(rw http.ResponseWriter, r *http.Request) {
	session := ctx.GetSession(r)
	// KeyHash() panics when the hash has not been cached on the session, so check first.
	if session == nil || session.KeyHashEmpty() {
		return
	}

	// Context variables only exist when "enable_context_vars" is on for the API. The map is the
	// same one the metrics recorder reads at the end of the request, so updating it in place is enough.
	if v := r.Context().Value(ctx.ContextData); v != nil {
		if contextData, ok := v.(map[string]interface{}); ok {
			contextData["hashed_api_key"] = session.KeyHash()
		}
	}
}

func main() {}
