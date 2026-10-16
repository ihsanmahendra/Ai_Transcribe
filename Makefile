.PHONY: app install dmg universal run clean

app:        ## Build build/AI Transcriber.app
	./build-app.sh

install:    ## Build lalu pasang ke /Applications
	./build-app.sh --install

dmg:        ## Build DMG untuk dibagikan (Apple Silicon + Intel)
	./build-app.sh --universal --dmg

run:        ## Jalankan langsung tanpa bundle (untuk development)
	swift run -c release

clean:
	rm -rf .build build
