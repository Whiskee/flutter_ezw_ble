package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals

class BlePendingOwnerPolicyTest {
    @Test
    fun `exact pre physical owner remains recyclable`() {
        assertEquals(
            BlePendingOwnerHealth.PRE_PHYSICAL,
            BlePendingOwnerPolicy.classify(
                exactDeviceGatt = true,
                hasAdmission = true,
                exactAdmittedGatt = false,
                hasBusinessGatt = false,
            ),
        )
    }

    @Test
    fun `physical and business owners are never recycled by pending deadline`() {
        assertEquals(
            BlePendingOwnerHealth.ADMITTED,
            BlePendingOwnerPolicy.classify(
                exactDeviceGatt = true,
                hasAdmission = true,
                exactAdmittedGatt = true,
                hasBusinessGatt = false,
            ),
        )
        assertEquals(
            BlePendingOwnerHealth.BUSINESS_CONNECTED,
            BlePendingOwnerPolicy.classify(
                exactDeviceGatt = true,
                hasAdmission = false,
                exactAdmittedGatt = false,
                hasBusinessGatt = true,
            ),
        )
    }

    @Test
    fun `missing manager identity is a stale owner instead of an active owner`() {
        assertEquals(
            BlePendingOwnerHealth.STALE,
            BlePendingOwnerPolicy.classify(
                exactDeviceGatt = false,
                hasAdmission = true,
                exactAdmittedGatt = false,
                hasBusinessGatt = false,
            ),
        )
        assertEquals(
            BlePendingOwnerHealth.STALE,
            BlePendingOwnerPolicy.classify(
                exactDeviceGatt = true,
                hasAdmission = false,
                exactAdmittedGatt = false,
                hasBusinessGatt = false,
            ),
        )
    }
}
