package utils

import "core:flags"
import "core:fmt"
import "core:os"

parse_args :: proc() -> Config {
	cfg := config_default()
	flags.parse_or_exit(&cfg, os.args)
	if msg := config_validate(&cfg); msg != "" {
		fmt.eprintln("odysseus:", msg)
		os.exit(2)
	}
	return cfg
}
