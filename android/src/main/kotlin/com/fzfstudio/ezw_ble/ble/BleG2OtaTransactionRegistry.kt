package com.fzfstudio.ezw_ble.ble

import java.util.UUID

internal data class BleG2OtaEndpointIdentity(
    val uuid: String,
    val name: String = "",
    val sessionGeneration: Long = 0L,
    val attemptGeneration: Long = 0L,
) {
    val key: String = uuid.lowercase()
}

internal enum class BleG2OtaEndpointAction(val flutterValue: String) {
    BIND("bind"),
    RECOVER("recover"),
    PARK("park");

    companion object {
        fun fromFlutterValue(value: String?): BleG2OtaEndpointAction? =
            entries.firstOrNull { it.flutterValue == value }
    }
}

internal enum class BleG2OtaTransactionStatus(val flutterValue: String) {
    ACCEPTED("accepted"),
    COMMITTED("committed"),
    ALREADY_COMMITTED("alreadyCommitted"),
    ACTIVE("active"),
    STALE_OWNER("staleOwner"),
    INVALID_REQUEST("invalidRequest"),
    UNAVAILABLE("unavailable"),
    UNKNOWN("unknown"),
    INVALIDATED("invalidated"),
    REVOKED("revoked"),
}

internal data class BleG2OtaTransactionResult(
    val status: BleG2OtaTransactionStatus,
    val transactionId: String,
    val generation: Long,
    val instanceId: String = "",
    val reason: String = "",
) {
    fun toFlutterMap(): Map<String, Any> = mapOf(
        "status" to status.flutterValue,
        "transactionId" to transactionId,
        "generation" to generation,
        "instanceId" to instanceId,
        "reason" to reason,
    )
}

internal data class BleG2OtaNativeContext(
    val transactionId: String,
    val generation: Long,
    val instanceId: String,
)

/**
 * Process-local owner ledger for G2 OTA.
 *
 * The registry owns logical transaction authority only. Live writes still use
 * the existing GATT/session/attempt checks in BleManager. Keeping those two
 * identities separate lets finish retire a transaction after Android has
 * already released the BluetoothGatt that quiteUpgradeState used to require.
 */
internal class BleG2OtaTransactionRegistry {
    private val nativeInstanceId = UUID.randomUUID().toString()

    private enum class EndpointState {
        WAITING,
        ACTIVE,
        RECOVERING,
        PARKED,
        RETIRING,
        RETIRED,
    }

    private data class EndpointLease(
        val uuid: String,
        val name: String,
        var sessionGeneration: Long,
        var attemptGeneration: Long,
        var state: EndpointState = EndpointState.WAITING,
    ) {
        val key: String = uuid.lowercase()

        fun samePhysicalPair(session: Long, attempt: Long): Boolean =
            sessionGeneration > 0L &&
                attemptGeneration > 0L &&
                sessionGeneration == session &&
                attemptGeneration == attempt
    }

    private data class Transaction(
        val transactionId: String,
        val generation: Long,
        val config: String,
        val sn: String,
        val instanceId: String,
        // The begin request is immutable transaction identity. Runtime endpoint leases
        // may move to a new physical pair during recovery and must not rewrite it.
        val beginEndpoints: Map<String, BleG2OtaEndpointIdentity>,
        val endpoints: MutableMap<String, EndpointLease>,
        var terminalStatus: BleG2OtaTransactionStatus? = null,
        var terminalReason: String = "",
    ) {
        fun sameBeginScope(
            generation: Long,
            config: String,
            sn: String,
            endpoints: List<BleG2OtaEndpointIdentity>,
        ): Boolean {
            if (this.generation != generation || this.config != config || this.sn != sn) {
                return false
            }
            val incoming = endpoints.associateBy { it.key }
            return incoming.keys == beginEndpoints.keys &&
                endpoints.all { endpoint ->
                    val initial = beginEndpoints[endpoint.key] ?: return@all false
                    initial.name == endpoint.name &&
                        initial.sessionGeneration == endpoint.sessionGeneration &&
                        initial.attemptGeneration == endpoint.attemptGeneration
                }
        }

        /**
         * Finish owns the logical transaction, not a caller-supplied physical GATT.
         *
         * Keep config/SN and the frozen endpoint set exact, but intentionally ignore
         * session/attempt values: recovery can legitimately rebind those values and
         * teardown must use the registry's current EndpointLease instead.
         */
        fun sameFinishScope(
            generation: Long,
            config: String,
            sn: String,
            endpoints: List<BleG2OtaEndpointIdentity>,
        ): Boolean {
            if (this.generation != generation || this.config != config || this.sn != sn) {
                return false
            }
            val incoming = endpoints.associateBy { it.key }
            return incoming.size == endpoints.size &&
                incoming.keys == beginEndpoints.keys &&
                endpoints.all { endpoint ->
                    val initial = beginEndpoints[endpoint.key] ?: return@all false
                    endpoint.hasValidPhysicalPairShape() && initial.name == endpoint.name
                }
        }

        fun result(status: BleG2OtaTransactionStatus, reason: String = terminalReason) =
            BleG2OtaTransactionResult(
                status = status,
                transactionId = transactionId,
                generation = generation,
                instanceId = instanceId,
                reason = reason,
            )
    }

    private val transactions = mutableMapOf<String, Transaction>()

    @Synchronized
    fun begin(
        transactionId: String,
        generation: Long,
        config: String,
        sn: String,
        endpoints: List<BleG2OtaEndpointIdentity>,
    ): BleG2OtaTransactionResult {
        if (!validScope(transactionId, generation, config, sn, endpoints)) {
            return BleG2OtaTransactionResult(
                status = BleG2OtaTransactionStatus.INVALID_REQUEST,
                transactionId = transactionId,
                generation = generation,
            )
        }
        val existing = transactions[transactionId]
        if (existing != null) {
            if (!existing.sameBeginScope(generation, config, sn, endpoints)) {
                return existing.result(BleG2OtaTransactionStatus.INVALID_REQUEST, "scopeConflict")
            }
            val terminal = existing.terminalStatus
            if (terminal != null) {
                return existing.result(terminal)
            }
            return existing.result(BleG2OtaTransactionStatus.ACCEPTED)
        }
        val overlap = endpoints
            .map { it.key }
            .toSet()
            .firstOrNull { key ->
                transactions.values.any { transaction ->
                    transaction.transactionId != transactionId &&
                        transaction.terminalStatus == null &&
                        transaction.endpoints.containsKey(key)
                }
            }
        if (overlap != null) {
            return BleG2OtaTransactionResult(
                status = BleG2OtaTransactionStatus.INVALID_REQUEST,
                transactionId = transactionId,
                generation = generation,
                instanceId = nativeInstanceId,
                reason = "endpointOverlap",
            )
        }
        val leases = endpoints.associate { endpoint ->
            endpoint.key to EndpointLease(
                uuid = endpoint.uuid,
                name = endpoint.name,
                sessionGeneration = endpoint.sessionGeneration,
                attemptGeneration = endpoint.attemptGeneration,
            )
        }.toMutableMap()
        val transaction = Transaction(
            transactionId = transactionId,
            generation = generation,
            config = config,
            sn = sn,
            instanceId = nativeInstanceId,
            beginEndpoints = endpoints.associateBy { it.key },
            endpoints = leases,
        )
        transactions[transactionId] = transaction
        return transaction.result(BleG2OtaTransactionStatus.ACCEPTED)
    }

    @Synchronized
    fun updateEndpoint(
        transactionId: String,
        generation: Long,
        instanceId: String,
        uuid: String,
        action: BleG2OtaEndpointAction?,
        sessionGeneration: Long,
        attemptGeneration: Long,
    ): BleG2OtaTransactionResult {
        val transaction = validOwner(transactionId, generation, instanceId)
            ?: return stale(transactionId, generation)
        val lease = transaction.endpoints[uuid.lowercase()]
            ?: return transaction.result(BleG2OtaTransactionStatus.INVALID_REQUEST, "endpointNotOwned")
        if (transaction.terminalStatus != null) {
            return transaction.result(transaction.terminalStatus!!)
        }
        if (action == null) {
            return transaction.result(BleG2OtaTransactionStatus.INVALID_REQUEST, "invalidAction")
        }
        when (action) {
            BleG2OtaEndpointAction.BIND -> {
                if (lease.state == EndpointState.PARKED ||
                    lease.state == EndpointState.RETIRING ||
                    lease.state == EndpointState.RETIRED
                ) {
                    return transaction.result(BleG2OtaTransactionStatus.STALE_OWNER, "endpointCompleted")
                }
                if (sessionGeneration <= 0L || attemptGeneration <= 0L) {
                    return transaction.result(BleG2OtaTransactionStatus.INVALID_REQUEST, "missingPhysicalPair")
                }
                lease.sessionGeneration = sessionGeneration
                lease.attemptGeneration = attemptGeneration
                lease.state = EndpointState.ACTIVE
            }
            BleG2OtaEndpointAction.RECOVER -> {
                if (lease.state == EndpointState.PARKED || lease.state == EndpointState.RETIRED) {
                    return transaction.result(BleG2OtaTransactionStatus.STALE_OWNER, "endpointCompleted")
                }
                val neverBoundWaiting = lease.state == EndpointState.WAITING &&
                    lease.sessionGeneration <= 0L &&
                    lease.attemptGeneration <= 0L &&
                    sessionGeneration == 0L &&
                    attemptGeneration == 0L
                if (!neverBoundWaiting && !lease.samePhysicalPair(sessionGeneration, attemptGeneration)) {
                    return transaction.result(BleG2OtaTransactionStatus.STALE_OWNER, "physicalPairMismatch")
                }
                lease.state = EndpointState.RECOVERING
            }
            BleG2OtaEndpointAction.PARK -> {
                if (!lease.samePhysicalPair(sessionGeneration, attemptGeneration)) {
                    return transaction.result(BleG2OtaTransactionStatus.STALE_OWNER, "physicalPairMismatch")
                }
                lease.state = EndpointState.PARKED
            }
        }
        return transaction.result(BleG2OtaTransactionStatus.ACCEPTED)
    }

    @Synchronized
    fun prepareFinish(
        transactionId: String,
        generation: Long,
        instanceId: String,
        reason: String,
        config: String,
        sn: String,
        endpoints: List<BleG2OtaEndpointIdentity>,
    ): BleG2OtaTransactionResult {
        val existing = transactions[transactionId]
        if (existing == null) {
            return createTerminalTombstoneIfAllowed(
                transactionId = transactionId,
                generation = generation,
                instanceId = instanceId,
                reason = reason,
                config = config,
                sn = sn,
                endpoints = endpoints,
            )
        }
        val terminal = existing.terminalStatus
        if (terminal != null) {
            if (
                existing.generation != generation ||
                (instanceId.isNotBlank() && existing.instanceId != instanceId) ||
                !existing.sameFinishScope(generation, config, sn, endpoints)
            ) {
                return existing.result(BleG2OtaTransactionStatus.STALE_OWNER, "ownerMismatch")
            }
            return existing.result(
                if (terminal == BleG2OtaTransactionStatus.COMMITTED) {
                    BleG2OtaTransactionStatus.ALREADY_COMMITTED
                } else {
                    terminal
                },
            )
        }
        if (!existing.acceptsMutableFinishOwner(generation, instanceId, reason, config, sn, endpoints)) {
            return existing.result(BleG2OtaTransactionStatus.STALE_OWNER, "ownerMismatch")
        }
        existing.endpoints.values.forEach { it.state = EndpointState.RETIRING }
        return existing.result(BleG2OtaTransactionStatus.ACCEPTED, reason)
    }

    @Synchronized
    fun commitFinish(
        transactionId: String,
        generation: Long,
        instanceId: String,
        reason: String,
        config: String,
        sn: String,
        endpoints: List<BleG2OtaEndpointIdentity>,
    ): BleG2OtaTransactionResult {
        val existing = transactions[transactionId]
            ?: return createTerminalTombstoneIfAllowed(
                transactionId = transactionId,
                generation = generation,
                instanceId = instanceId,
                reason = reason,
                config = config,
                sn = sn,
                endpoints = endpoints,
            )
        val terminal = existing.terminalStatus
        if (terminal != null) {
            if (
                existing.generation != generation ||
                (instanceId.isNotBlank() && existing.instanceId != instanceId) ||
                !existing.sameFinishScope(generation, config, sn, endpoints)
            ) {
                return existing.result(BleG2OtaTransactionStatus.STALE_OWNER, "ownerMismatch")
            }
            return existing.result(
                if (terminal == BleG2OtaTransactionStatus.COMMITTED) {
                    BleG2OtaTransactionStatus.ALREADY_COMMITTED
                } else {
                    terminal
                },
            )
        }
        if (
            !existing.acceptsMutableFinishOwner(generation, instanceId, reason, config, sn, endpoints) ||
            existing.endpoints.values.any { it.state != EndpointState.RETIRING }
        ) {
            return existing.result(BleG2OtaTransactionStatus.STALE_OWNER, "ownerMismatch")
        }
        existing.endpoints.values.forEach { it.state = EndpointState.RETIRED }
        existing.terminalStatus = when (reason) {
            "revoked" -> BleG2OtaTransactionStatus.REVOKED
            else -> BleG2OtaTransactionStatus.COMMITTED
        }
        existing.terminalReason = reason
        return existing.result(existing.terminalStatus!!)
    }

    @Synchronized
    fun query(
        transactionId: String,
        generation: Long,
        instanceId: String,
    ): BleG2OtaTransactionResult {
        val transaction = transactions[transactionId]
        if (transaction == null) {
            // Absence only proves this process has no matching ledger. If Dart presents a
            // positive owner stamped by a different native-instance nonce, report that the
            // old process-local credential cannot control this process; same-instance
            // misses remain unknown so callers do not infer a successful cleanup by UUID.
            val status = if (generation > 0L && instanceId.isNotBlank() && instanceId != nativeInstanceId) {
                BleG2OtaTransactionStatus.INVALIDATED
            } else {
                BleG2OtaTransactionStatus.UNKNOWN
            }
            val reason = if (status == BleG2OtaTransactionStatus.INVALIDATED) {
                "nativeInstanceRecreated"
            } else {
                ""
            }
            return BleG2OtaTransactionResult(
                status = status,
                transactionId = transactionId,
                generation = generation,
                instanceId = instanceId,
                reason = reason,
            )
        }
        if (transaction.generation != generation || (instanceId.isNotBlank() && transaction.instanceId != instanceId)) {
            return transaction.result(BleG2OtaTransactionStatus.STALE_OWNER, "ownerMismatch")
        }
        val terminal = transaction.terminalStatus
        return transaction.result(
            if (terminal == BleG2OtaTransactionStatus.COMMITTED) {
                BleG2OtaTransactionStatus.ALREADY_COMMITTED
            } else {
                terminal ?: BleG2OtaTransactionStatus.ACTIVE
            },
        )
    }

    @Synchronized
    fun hasTransaction(transactionId: String): Boolean =
        transactions.containsKey(transactionId)

    @Synchronized
    fun ownsEndpoint(uuid: String): Boolean =
        transactions.values.any { transaction ->
            transaction.terminalStatus == null &&
                transaction.endpoints.containsKey(uuid.lowercase())
        }

    @Synchronized
    fun acceptsContext(
        transactionId: String,
        generation: Long,
        instanceId: String,
        uuid: String,
    ): Boolean {
        val transaction = transactions[transactionId] ?: return false
        val lease = transaction.endpoints[uuid.lowercase()] ?: return false
        return transaction.terminalStatus == null &&
            transaction.generation == generation &&
            transaction.instanceId == instanceId &&
            (lease.state == EndpointState.ACTIVE || lease.state == EndpointState.RECOVERING)
    }

    @Synchronized
    fun acceptsRecoveryContext(
        transactionId: String,
        generation: Long,
        instanceId: String,
        uuid: String,
    ): Boolean {
        val transaction = transactions[transactionId] ?: return false
        val lease = transaction.endpoints[uuid.lowercase()] ?: return false
        return transaction.terminalStatus == null &&
            transaction.generation == generation &&
            transaction.instanceId == instanceId &&
            lease.state == EndpointState.RECOVERING
    }

    /**
     * Authorize teardown of the exact pre-recovery physical owner.
     *
     * A recovery credential identifies the logical transaction, while the frozen
     * session/attempt pair identifies the one old GATT that may be replaced. Both
     * must still match while the endpoint is RECOVERING; an ACTIVE/PARKED endpoint,
     * a stale native instance, or a different physical attempt fails closed.
     */
    @Synchronized
    fun acceptsRecoveryPhysicalPair(
        context: BleG2OtaNativeContext,
        uuid: String,
        sessionGeneration: Long,
        attemptGeneration: Long,
    ): Boolean {
        val transaction = transactions[context.transactionId] ?: return false
        val lease = transaction.endpoints[uuid.lowercase()] ?: return false
        return transaction.terminalStatus == null &&
            transaction.generation == context.generation &&
            transaction.instanceId == context.instanceId &&
            lease.state == EndpointState.RECOVERING &&
            lease.samePhysicalPair(sessionGeneration, attemptGeneration)
    }

    @Synchronized
    fun endpointIds(transactionId: String): List<String> =
        transactions[transactionId]?.endpoints?.values?.map { it.uuid }.orEmpty()

    @Synchronized
    fun endpointIdentities(transactionId: String): List<BleG2OtaEndpointIdentity> =
        transactions[transactionId]?.endpoints?.values?.map { lease ->
            BleG2OtaEndpointIdentity(
                uuid = lease.uuid,
                name = lease.name,
                sessionGeneration = lease.sessionGeneration,
                attemptGeneration = lease.attemptGeneration,
            )
        }.orEmpty()

    @Synchronized
    fun revokeTransactionsForEndpoints(endpointIds: Set<String>, reason: String): List<BleG2OtaEndpointIdentity> {
        val keys = endpointIds.map { it.lowercase() }.toSet()
        if (keys.isEmpty()) {
            return emptyList()
        }
        return transactions.values
            .filter { transaction ->
                transaction.terminalStatus == null &&
                    transaction.endpoints.keys.any { it in keys }
            }
            .flatMap { transaction ->
                transaction.endpoints.values.forEach { it.state = EndpointState.RETIRED }
                transaction.terminalStatus = BleG2OtaTransactionStatus.REVOKED
                transaction.terminalReason = reason
                transaction.endpoints.values.map { lease ->
                    BleG2OtaEndpointIdentity(
                        uuid = lease.uuid,
                        name = lease.name,
                        sessionGeneration = lease.sessionGeneration,
                        attemptGeneration = lease.attemptGeneration,
                    )
                }
            }
            .distinctBy { it.key }
    }

    @Synchronized
    fun activeContextForEndpoint(uuid: String): BleG2OtaNativeContext? =
        transactions.values.firstOrNull { transaction ->
            transaction.terminalStatus == null &&
                transaction.endpoints.containsKey(uuid.lowercase())
        }?.let { transaction ->
            BleG2OtaNativeContext(
                transactionId = transaction.transactionId,
                generation = transaction.generation,
                instanceId = transaction.instanceId,
            )
        }

    @Synchronized
    fun clearInvalidated(reason: String) {
        transactions.values
            .filter { it.terminalStatus == null }
            .forEach { transaction ->
                transaction.terminalStatus = BleG2OtaTransactionStatus.INVALIDATED
                transaction.terminalReason = reason
            }
    }

    private fun validOwner(
        transactionId: String,
        generation: Long,
        instanceId: String,
    ): Transaction? {
        val transaction = transactions[transactionId] ?: return null
        if (transaction.generation != generation || transaction.instanceId != instanceId) {
            return null
        }
        return transaction
    }

    /**
     * Mutable finish operations need the native instance credential except for the one
     * contract carve-out: Dart may cancel an exact pre-allocated transaction whose
     * begin ACK was lost. Success/failed cleanup with a blank instance would otherwise
     * let a stale caller retire a live OTA group it no longer owns.
     */
    private fun Transaction.acceptsMutableFinishOwner(
        generation: Long,
        instanceId: String,
        reason: String,
        config: String,
        sn: String,
        endpoints: List<BleG2OtaEndpointIdentity>,
    ): Boolean {
        if (this.generation != generation || !sameFinishScope(generation, config, sn, endpoints)) {
            return false
        }
        return if (instanceId.isNotBlank()) {
            this.instanceId == instanceId
        } else {
            reason == "cancelled"
        }
    }

    private fun stale(transactionId: String, generation: Long) = BleG2OtaTransactionResult(
        status = BleG2OtaTransactionStatus.STALE_OWNER,
        transactionId = transactionId,
        generation = generation,
    )

    private fun createTerminalTombstoneIfAllowed(
        transactionId: String,
        generation: Long,
        instanceId: String,
        reason: String,
        config: String,
        sn: String,
        endpoints: List<BleG2OtaEndpointIdentity>,
    ): BleG2OtaTransactionResult {
        if (
            (reason == "cancelled" || reason == "revoked") &&
            instanceId.isBlank() &&
            validScope(transactionId, generation, config, sn, endpoints)
        ) {
            val transaction = Transaction(
                transactionId = transactionId,
                generation = generation,
                config = config,
                sn = sn,
                instanceId = nativeInstanceId,
                beginEndpoints = endpoints.associateBy { it.key },
                endpoints = endpoints.associate { endpoint ->
                    endpoint.key to EndpointLease(
                        uuid = endpoint.uuid,
                        name = endpoint.name,
                        sessionGeneration = endpoint.sessionGeneration,
                        attemptGeneration = endpoint.attemptGeneration,
                        state = EndpointState.RETIRED,
                    )
                }.toMutableMap(),
                terminalStatus = if (reason == "revoked") {
                    BleG2OtaTransactionStatus.REVOKED
                } else {
                    BleG2OtaTransactionStatus.INVALIDATED
                },
                terminalReason = reason,
            )
            transactions[transactionId] = transaction
            return transaction.result(transaction.terminalStatus!!)
        }
        return BleG2OtaTransactionResult(
            status = if (reason == "revoked") {
                BleG2OtaTransactionStatus.REVOKED
            } else {
                BleG2OtaTransactionStatus.INVALIDATED
            },
            transactionId = transactionId,
            generation = generation,
            reason = "notRegistered",
        )
    }

    private fun validScope(
        transactionId: String,
        generation: Long,
        config: String,
        sn: String,
        endpoints: List<BleG2OtaEndpointIdentity>,
    ): Boolean =
        transactionId.isNotBlank() &&
            generation > 0L &&
            config.isNotBlank() &&
            sn.isNotBlank() &&
            endpoints.isNotEmpty() &&
            endpoints.all { it.uuid.isNotBlank() } &&
            endpoints.all { it.hasValidPhysicalPairShape() } &&
            endpoints.map { it.key }.toSet().size == endpoints.size
}

/** Reject partial, negative, or fabricated physical identities at every scope boundary. */
private fun BleG2OtaEndpointIdentity.hasValidPhysicalPairShape(): Boolean =
    (sessionGeneration == 0L && attemptGeneration == 0L) ||
        (sessionGeneration > 0L && attemptGeneration > 0L)
