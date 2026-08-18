package utils

import "core:flags"
import "core:os"

parse_args :: proc() -> Config {
	cfg := config_default()
	flags.parse_or_exit(&cfg, os.args)
	return cfg
}
