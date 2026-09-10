package cdrip

import (
	"encoding/binary"
	"io"
	"os"
)

func WritePCM16LE(path string, pcm []byte) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := writePCM16LEHeader(file, int64(len(pcm))); err != nil {
		return err
	}
	_, err = file.Write(pcm)
	return err
}

// WritePCM16LEStream writes a WAV header and streams exactly dataSize bytes into it.
func WritePCM16LEStream(path string, dataSize int64, writePCM func(io.Writer) error) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	if err := writePCM16LEHeader(file, dataSize); err != nil {
		return err
	}
	return writePCM(file)
}

func writePCM16LEHeader(writer io.Writer, dataSize int64) error {
	header := make([]byte, 44)
	copy(header[0:4], "RIFF")
	binary.LittleEndian.PutUint32(header[4:8], uint32(36+dataSize))
	copy(header[8:12], "WAVE")
	copy(header[12:16], "fmt ")
	binary.LittleEndian.PutUint32(header[16:20], 16)
	binary.LittleEndian.PutUint16(header[20:22], 1)
	binary.LittleEndian.PutUint16(header[22:24], 2)
	binary.LittleEndian.PutUint32(header[24:28], 44100)
	binary.LittleEndian.PutUint32(header[28:32], 44100*4)
	binary.LittleEndian.PutUint16(header[32:34], 4)
	binary.LittleEndian.PutUint16(header[34:36], 16)
	copy(header[36:40], "data")
	binary.LittleEndian.PutUint32(header[40:44], uint32(dataSize))
	_, err := writer.Write(header)
	return err
}
