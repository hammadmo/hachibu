# Probes

Small command-line tools written while working out how charging can be
controlled on macOS 27. They are research tools, not part of Hachibu:
the app does not build, ship, or call any of them. What they found is
written up in [`docs/research/charge-control.md`](../docs/research/charge-control.md).

| File | What it does |
| --- | --- |
| `smc_probe.c` | Reads battery and charger values from the SMC. Read-only. |
| `powerui_probe.m` | Reads the charge limit macOS holds, through the PowerUI framework. Read-only. |
| `powerui_set.m` | Sets a charge limit through PowerUI. |
| `chie_test.c` | Cuts and reconnects the charger through the SMC, as root. |

`chie_test.c` is why Hachibu has no "discharge" mode: on macOS 27 a cut
made this way could leave the Mac on battery after it was released. The
app and its helper contain no code that cuts the charger; the helper can
only reconnect one.

Build one with `cc` if you want to repeat a measurement, for example
`cc -framework IOKit -framework CoreFoundation smc_probe.c -o smc_probe`.
Run the ones that change something only if you know what they do.
