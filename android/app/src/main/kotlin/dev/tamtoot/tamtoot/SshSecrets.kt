package dev.tamtoot.tamtoot

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Secrets live in noBackupFilesDir, encrypted by a non-exportable Keystore key. */
class SshSecrets(private val context: Context, messenger: BinaryMessenger) {
    private val alias = "dev.tamtoot.ssh.secrets.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    init {
        MethodChannel(messenger, "dev.tamtoot/ssh_secrets").setMethodCallHandler { call, result ->
            try {
                if (call.method == "available") {
                    key()
                    result.success(true)
                } else {
                    val id = call.argument<String>("id") ?: throw IllegalArgumentException()
                    require(id.matches(Regex("^[a-f0-9]{32}$")))
                    val directory = File(context.noBackupFilesDir, "ssh-secrets")
                    check(directory.isDirectory || directory.mkdirs())
                    val file = AtomicFile(File(directory, id))
                    when (call.method) {
                        "write" -> {
                            val value = call.argument<ByteArray>("value") ?: throw IllegalArgumentException()
                            require(value.isNotEmpty() && value.size <= 65536)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            cipher.init(Cipher.ENCRYPT_MODE, key())
                            cipher.updateAAD(id.toByteArray(Charsets.US_ASCII))
                            val encrypted = cipher.doFinal(value)
                            val output = file.startWrite()
                            try {
                                output.write(cipher.iv)
                                output.write(encrypted)
                                file.finishWrite(output)
                            } catch (error: Exception) { file.failWrite(output); throw error }
                            finally { value.fill(0) }
                            result.success(null)
                        }
                        "read" -> {
                            val bytes = try { file.readFully() } catch (_: java.io.FileNotFoundException) { null }
                            if (bytes == null) result.success(null)
                            else {
                                require(bytes.size in 29..65564)
                                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                                cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                                cipher.updateAAD(id.toByteArray(Charsets.US_ASCII))
                                result.success(cipher.doFinal(bytes, 12, bytes.size - 12))
                            }
                        }
                        "delete" -> {
                            file.delete()
                            check(!file.baseFile.exists() &&
                                !File(file.baseFile.path + ".bak").exists() &&
                                !File(file.baseFile.path + ".new").exists())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            } catch (_: Exception) {
                if (call.method == "available") result.success(false)
                else result.error("secure_storage", "Android secure storage operation failed", null)
            }
        }
    }
}
