echo "Stopping sandbox container..."
sudo incus stop sandbox

echo "Deleting sandbox container..."
sudo incus delete sandbox --force

echo "Showing remaining containers..."
sudo incus list

echo "done."
