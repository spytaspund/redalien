<p align="center">
<img width="460" height="128" alt="redalien-banner" src="https://github.com/user-attachments/assets/55adb580-28c8-4b24-84cb-0823d01b0023" />
</p>
<p align="center">Various fixes for AlienBlue and other Reddit clients</p>

This tweak aims to fix as many old iOS Alien Blue Reddit client features as possible.

Minimum development target is `iOS 3.0 (armv6)`.

#### What this tweak fixes?
1. Sign In (via OAuth)
2. Personalized feed
3. DMs
4. Regular posts, subreddits, comments
5. Photos
6. Galleries
7. Videos
8. Subreddit icons

## Building

1. You'll need to install [Theos](https://theos.dev/docs/installation).
2. Clone the repository `git clone https://github.com/spytaspund/redalien`
3. Run `make package` to build `.deb` file in `packages/` directory.
4. Run `THEOS_DEVICE_IP="YOUR_DEVICE_IP" make package install` to install `.deb` on your iOS device directly via SSH.
