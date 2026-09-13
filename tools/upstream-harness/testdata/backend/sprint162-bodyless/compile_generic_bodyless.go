// Negative control: generic declarations without bodies remain a gc error.
package bodyless

func generic[T any]()
