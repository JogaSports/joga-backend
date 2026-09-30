# Everyday commands. Requires the Supabase CLI and Docker; Deno for the
# function checks.

FUNCTIONS := create-payment stripe-webhook revenuecat-webhook

.PHONY: start stop reset test lint functions-serve functions-check deploy

start:            ## Start Supabase locally (API, database, studio)
	supabase start

stop:
	supabase stop

reset:            ## Rebuild the local database: migrations + seed
	supabase db reset

test:             ## Run the database tests (pgTAP)
	supabase test db

lint:             ## Lint the database schema and functions
	supabase db lint --level warning

functions-serve:  ## Run edge functions locally with secrets from supabase/functions/.env
	supabase functions serve --env-file supabase/functions/.env

functions-check:  ## Format, lint and type-check edge functions
	deno fmt --check --line-width 100 supabase/functions
	deno lint supabase/functions
	@for f in $(FUNCTIONS); do \
	  deno check --config supabase/functions/$$f/deno.json supabase/functions/$$f/index.ts || exit 1; \
	done

deploy:           ## Push migrations and deploy functions to the linked project
	supabase db push
	supabase functions deploy
