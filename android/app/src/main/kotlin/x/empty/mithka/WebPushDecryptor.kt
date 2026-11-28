package x.empty.mithka

import android.util.Base64
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.interfaces.ECPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Arrays
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Decrypts a WebPush aesgcm (draft 4) message with the app's P-256 key.
 *
 * The UnifiedPush PUT-to-POST gateway folds the request's `Encryption` and
 * `Crypto-Key` headers into the body because a distributor forwards only the
 * body; this parser accepts that shape. Port of exteraless's
 * `WebPushDecryptor`.
 */
object WebPushDecryptor {
    @Throws(Exception::class)
    fun decrypt(
        body: ByteArray,
        pkcs8PrivateKey: ByteArray,
        rawPublicKey: ByteArray,
        authSecret: ByteArray,
    ): ByteArray {
        var newlineCount = 0
        var splitPos = -1
        for (index in body.indices) {
            if (body[index] == '\n'.code.toByte()) {
                newlineCount++
                if (newlineCount == 3) {
                    splitPos = index + 1
                    break
                }
            }
        }
        require(splitPos in 0 until body.size) {
            "Invalid message format: missing header/ciphertext separator"
        }

        val headers = String(body, 0, splitPos, StandardCharsets.UTF_8)
        val ciphertext = Arrays.copyOfRange(body, splitPos, body.size)

        var salt: ByteArray? = null
        for (line in headers.split("\n")) {
            val trimmed = line.trim()
            if (trimmed.startsWith("Encryption:")) {
                for (part in trimmed.substring("Encryption:".length).trim().split(";")) {
                    val item = part.trim()
                    if (item.startsWith("salt=")) {
                        salt = Base64.decode(
                            item.substring(5),
                            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
                        )
                    }
                }
            }
        }
        val saltBytes = requireNotNull(salt) { "Missing salt in Encryption header" }

        var serverPublic: ByteArray? = null
        for (line in headers.split("\n")) {
            val trimmed = line.trim()
            if (trimmed.startsWith("Crypto-Key:")) {
                for (part in trimmed.substring("Crypto-Key:".length).trim().split(";")) {
                    val item = part.trim()
                    if (item.startsWith("dh=")) {
                        serverPublic = Base64.decode(
                            item.substring(3),
                            Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
                        )
                    }
                }
            }
        }
        val serverPublicBytes = requireNotNull(serverPublic) {
            "Missing dh in Crypto-Key header"
        }

        val keyFactory = KeyFactory.getInstance("EC")
        val privateKey = keyFactory.generatePrivate(PKCS8EncodedKeySpec(pkcs8PrivateKey))
        val serverKey = rawToEcPublicKey(serverPublicBytes)

        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(serverKey, true)
        val sharedSecret = agreement.generateSecret()

        val prk = hmacSha256(authSecret, sharedSecret)
        val authInfo = "Content-Encoding: auth\u0000".toByteArray(StandardCharsets.UTF_8)
        val inputKeyMaterial = hkdfExpand(prk, authInfo, 32)

        val prk2 = hmacSha256(saltBytes, inputKeyMaterial)
        val context = buildContext(rawPublicKey, serverPublicBytes)

        val cekInfo = concat(
            "Content-Encoding: aesgcm\u0000".toByteArray(StandardCharsets.UTF_8),
            context,
        )
        val contentEncryptionKey = hkdfExpand(prk2, cekInfo, 16)

        val nonceInfo = concat(
            "Content-Encoding: nonce\u0000".toByteArray(StandardCharsets.UTF_8),
            context,
        )
        val nonce = hkdfExpand(prk2, nonceInfo, 12)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(contentEncryptionKey, "AES"),
            GCMParameterSpec(128, nonce),
        )
        val decrypted = cipher.doFinal(ciphertext)

        require(decrypted.size >= 2) { "Decrypted payload too short" }
        val paddingLength =
            ((decrypted[0].toInt() and 0xFF) shl 8) or (decrypted[1].toInt() and 0xFF)
        require(2 + paddingLength <= decrypted.size) { "Invalid padding length" }
        return Arrays.copyOfRange(decrypted, 2 + paddingLength, decrypted.size)
    }

    fun extractRawPublicKey(key: ECPublicKey): ByteArray {
        val point = key.w
        val xBytes = point.affineX.toByteArray()
        val yBytes = point.affineY.toByteArray()
        val raw = ByteArray(65)
        raw[0] = 0x04
        if (xBytes.size >= 32) {
            System.arraycopy(xBytes, xBytes.size - 32, raw, 1, 32)
        } else {
            System.arraycopy(xBytes, 0, raw, 1 + (32 - xBytes.size), xBytes.size)
        }
        if (yBytes.size >= 32) {
            System.arraycopy(yBytes, yBytes.size - 32, raw, 33, 32)
        } else {
            System.arraycopy(yBytes, 0, raw, 33 + (32 - yBytes.size), yBytes.size)
        }
        return raw
    }

    private fun rawToEcPublicKey(rawPoint: ByteArray): ECPublicKey {
        val header = byteArrayOf(
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(),
            0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d,
            0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        )
        val encoded = ByteArray(header.size + rawPoint.size)
        System.arraycopy(header, 0, encoded, 0, header.size)
        System.arraycopy(rawPoint, 0, encoded, header.size, rawPoint.size)
        return KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(encoded)) as ECPublicKey
    }

    private fun buildContext(clientPublic: ByteArray, serverPublic: ByteArray): ByteArray {
        val label = "P-256\u0000".toByteArray(StandardCharsets.UTF_8)
        val context = ByteArray(
            label.size + 2 + clientPublic.size + 2 + serverPublic.size,
        )
        var offset = 0
        System.arraycopy(label, 0, context, offset, label.size)
        offset += label.size
        context[offset++] = (clientPublic.size shr 8).toByte()
        context[offset++] = clientPublic.size.toByte()
        System.arraycopy(clientPublic, 0, context, offset, clientPublic.size)
        offset += clientPublic.size
        context[offset++] = (serverPublic.size shr 8).toByte()
        context[offset++] = serverPublic.size.toByte()
        System.arraycopy(serverPublic, 0, context, offset, serverPublic.size)
        return context
    }

    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val input = Arrays.copyOf(info, info.size + 1)
        input[info.size] = 0x01
        return Arrays.copyOfRange(hmacSha256(prk, input), 0, length)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun concat(first: ByteArray, second: ByteArray): ByteArray {
        val result = Arrays.copyOf(first, first.size + second.size)
        System.arraycopy(second, 0, result, first.size, second.size)
        return result
    }
}
