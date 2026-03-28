<template>
  <modals-modal v-model="show" :width="320" height="100%">
    <div class="w-full h-full overflow-hidden absolute top-0 left-0 flex items-center justify-center" @click="cancelIfIdle">
      <div class="w-full overflow-x-hidden overflow-y-auto bg-primary rounded-lg border border-fg/20 p-6" style="max-height: 75%" @click.stop>
        <!-- Confirmation state -->
        <template v-if="state === 'confirm'">
          <p class="text-fg text-lg text-center mb-2">Authorize device?</p>
          <p class="text-fg-muted text-sm text-center mb-4">Verify this code matches your device</p>
          <p class="text-fg text-3xl font-bold text-center tracking-widest my-4">{{ userCode }}</p>
          <p class="text-fg-muted text-xs text-center mb-6 truncate">{{ serverAddress }}</p>
          <div class="flex space-x-3">
            <ui-btn class="flex-1" @click="cancel">Cancel</ui-btn>
            <ui-btn class="flex-1" color="success" @click="authorize">Authorize</ui-btn>
          </div>
        </template>

        <!-- Authorizing state -->
        <template v-if="state === 'authorizing'">
          <div class="flex flex-col items-center py-4">
            <div class="w-8 h-8 border-2 border-fg/20 border-t-fg rounded-full animate-spin mb-4" />
            <p class="text-fg text-base">Authorizing...</p>
          </div>
        </template>

        <!-- Success state -->
        <template v-if="state === 'success'">
          <div class="flex flex-col items-center py-4">
            <span class="material-symbols text-success text-4xl mb-2">check_circle</span>
            <p class="text-fg text-lg">Device authorized!</p>
          </div>
        </template>

        <!-- Error state -->
        <template v-if="state === 'error'">
          <div class="flex flex-col items-center py-4">
            <span class="material-symbols text-error text-4xl mb-2">error</span>
            <p class="text-fg text-base text-center mb-4">{{ errorMessage }}</p>
            <ui-btn class="w-full" @click="cancel">Close</ui-btn>
          </div>
        </template>
      </div>
    </div>
  </modals-modal>
</template>

<script>
import { CapacitorHttp } from '@capacitor/core'

export default {
  data() {
    return {
      show: false,
      state: 'confirm', // confirm, authorizing, success, error
      userCode: '',
      serverAddress: '',
      serverToken: '',
      errorMessage: ''
    }
  },
  methods: {
    open({ userCode, serverAddress, serverToken }) {
      this.userCode = userCode
      this.serverAddress = serverAddress
      this.serverToken = serverToken
      this.errorMessage = ''
      this.state = 'confirm'
      this.show = true
    },
    cancelIfIdle() {
      if (this.state === 'confirm' || this.state === 'error' || this.state === 'success') {
        this.cancel()
      }
    },
    cancel() {
      this.show = false
    },
    async authorize() {
      this.state = 'authorizing'

      try {
        const response = await CapacitorHttp.post({
          url: `${this.serverAddress}/api/device-code/authorize`,
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${this.serverToken}`
          },
          data: { userCode: this.userCode }
        })

        if (response.status === 200 && response.data?.success) {
          this.state = 'success'
          setTimeout(() => {
            this.show = false
          }, 2000)
        } else {
          this.errorMessage = response.data?.error || 'Authorization failed'
          this.state = 'error'
        }
      } catch (error) {
        console.error('[DeviceCodeAuthorize] Error authorizing device:', error)
        this.errorMessage = error.message || 'Failed to authorize device'
        this.state = 'error'
      }
    }
  }
}
</script>
