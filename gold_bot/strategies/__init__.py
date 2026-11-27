"""32-strategy Gold scalping engine, split into 6 pods."""
from . import (pod_liquidity, pod_momentum, pod_reversion, pod_sessions,
               pod_smc, pod_volume)

PODS = {
    "momentum": pod_momentum.STRATEGIES,
    "liquidity": pod_liquidity.STRATEGIES,
    "smc": pod_smc.STRATEGIES,
    "volume": pod_volume.STRATEGIES,
    "reversion": pod_reversion.STRATEGIES,
    "sessions": pod_sessions.STRATEGIES,
}

ALL = [item for pod in PODS.values() for item in pod]
NAMES = tuple(name for name, _ in ALL)

assert len(NAMES) == 32, f"expected 32 strategies, found {len(NAMES)}"
assert len(set(NAMES)) == 32, "duplicate strategy names"
